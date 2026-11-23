import Foundation

/// Read-only adapter for WorkBuddy (`~/.workbuddy/workbuddy.db` short-lived WAL read with JSON fallback).
public final class WorkBuddyAdapter: AgentAdapter, @unchecked Sendable {
    public let source: AgentSource = .workbuddy
    public let rootDirectory: String
    public let activeWindowSeconds: TimeInterval

    private let lock = NSLock()
    private var _healthStatus: AdapterHealth = .idle
    private var lifecycleGeneration: UInt64 = 0
    private let epoch: String
    private var seqCounter: UInt64 = 0
    private var consecutiveSQLiteFailures: Int = 0
    private var lastEmittedSignature: [String: String] = [:]
    private let watcher: FSEventWatcher
    private let coalescer = AdapterRefreshCoalescer(delay: .milliseconds(150))
    private let workQueue = DispatchQueue(label: "com.codepilot.adapter.workbuddy", qos: .utility)
    private var emitHandler: (@Sendable (TaskEvent) -> Void)?

    public var healthStatus: AdapterHealth {
        lock.lock()
        defer { lock.unlock() }
        return _healthStatus
    }

    public static var defaultRootDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.workbuddy"
    }

    public init(
        rootDirectory: String = WorkBuddyAdapter.defaultRootDirectory,
        activeWindowSeconds: TimeInterval = 24 * 3600,
        epoch: String = "wb-\(UUID().uuidString.prefix(8))"
    ) {
        self.rootDirectory = rootDirectory
        self.activeWindowSeconds = max(60, activeWindowSeconds)
        self.epoch = epoch
        self.watcher = FSEventWatcher(label: "com.codepilot.fsevents.workbuddy")
    }

    deinit {
        stop()
    }

    public func start(emit: @escaping @Sendable (TaskEvent) -> Void) {
        let gen: UInt64
        lock.lock()
        lifecycleGeneration &+= 1
        gen = lifecycleGeneration
        emitHandler = emit
        consecutiveSQLiteFailures = 0
        lastEmittedSignature.removeAll()
        lock.unlock()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootDirectory, isDirectory: &isDir), isDir.boolValue else {
            setHealth(.notInstalled)
            return
        }

        do {
            _ = try fm.contentsOfDirectory(atPath: rootDirectory)
        } catch let err as NSError {
            if err.domain == NSCocoaErrorDomain && err.code == NSFileReadNoPermissionError ||
                err.domain == NSPOSIXErrorDomain && err.code == Int(EPERM) {
                setHealth(.permissionDenied(path: rootDirectory))
            } else {
                setHealth(.error(err.localizedDescription))
            }
            return
        }

        setHealth(.active(watchedPath: rootDirectory))

        workQueue.async { [weak self] in
            self?.refresh(isPriming: true, expectedGeneration: gen)
        }

        _ = watcher.start(paths: [rootDirectory], latency: 0.1) { [weak self] changedPaths in
            guard let self else { return }
            let relevant = changedPaths.contains {
                $0.hasSuffix("workbuddy.db") || $0.hasSuffix("workbuddy.db-wal") || $0.contains("/sessions/")
            }
            guard relevant else { return }
            Task { [weak self] in
                await self?.coalescer.schedule(key: "wb_refresh") { [weak self] in
                    self?.workQueue.async { [weak self] in
                        guard let self, self.isCurrentGeneration(gen) else { return }
                        self.refresh(isPriming: false, expectedGeneration: gen)
                    }
                }
            }
        }
    }

    public func stop() {
        watcher.stop()
        Task { [coalescer] in
            await coalescer.cancelAll()
        }
        lock.lock()
        lifecycleGeneration &+= 1
        emitHandler = nil
        lastEmittedSignature.removeAll()
        _healthStatus = .idle
        lock.unlock()
    }

    public func pollIfNeeded() {
        let gen = currentGeneration()
        guard case .active = healthStatus else { return }
        workQueue.async { [weak self] in
            self?.refresh(isPriming: false, expectedGeneration: gen)
        }
    }

    /// Exposed for deterministic unit testing.
    public func refreshOnce(isPriming: Bool = false) {
        refresh(isPriming: isPriming, expectedGeneration: currentGeneration())
    }

    private func refresh(isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }

        let dbPath = "\(rootDirectory)/workbuddy.db"
        let useFallback: Bool
        lock.lock()
        useFallback = consecutiveSQLiteFailures >= 3 || !FileManager.default.fileExists(atPath: dbPath)
        lock.unlock()

        if !useFallback {
            do {
                try querySQLite(at: dbPath, isPriming: isPriming, expectedGeneration: expectedGeneration)
                lock.lock()
                consecutiveSQLiteFailures = 0
                lock.unlock()
                return
            } catch {
                lock.lock()
                consecutiveSQLiteFailures += 1
                let count = consecutiveSQLiteFailures
                lock.unlock()
                if count >= 3 {
                    setHealth(.active(watchedPath: "\(rootDirectory)/sessions (JSON 降级)"))
                }
            }
        }

        fallbackScanSessionsJSON(isPriming: isPriming, expectedGeneration: expectedGeneration)
    }

    private func querySQLite(at dbPath: String, isPriming: Bool, expectedGeneration: UInt64) throws {
        let db = ReadOnlySQLite(path: dbPath, busyTimeoutMs: 200)

        // 1. Pending user interruptions -> waiting_user
        var interruptedSessions = Set<String>()
        if let intRows = try? db.query("SELECT session_id FROM session_turn_interruptions") {
            for r in intRows {
                if let sid = r["session_id"]?.stringValue {
                    interruptedSessions.insert(sid)
                }
            }
        }

        // 2. Running background automations -> running
        var runningAutomations = Set<String>()
        if let autoRows = try? db.query("SELECT running_conversation_id FROM automation_runtime_state WHERE running = 1") {
            for r in autoRows {
                if let sid = r["running_conversation_id"]?.stringValue {
                    runningAutomations.insert(sid)
                }
            }
        }

        // 3. Recent sessions
        let cutoffMs = Int64((Date().timeIntervalSince1970 - activeWindowSeconds) * 1000)
        let sessionRows = try db.query("""
            SELECT id, cwd, title, custom_title, status, updated_at, last_activity_at
            FROM sessions
            WHERE deleted_at IS NULL
              AND (COALESCE(last_activity_at, updated_at, 0) >= \(cutoffMs) OR status != 'completed')
            ORDER BY COALESCE(last_activity_at, updated_at, 0) DESC
            LIMIT 30
        """)

        let now = Date()
        for row in sessionRows {
            guard isCurrentGeneration(expectedGeneration) else { return }
            guard let sid = row["id"]?.stringValue, !sid.isEmpty else { continue }

            let customTitle = row["custom_title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTitle = row["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = row["cwd"]?.stringValue
            let dbStatus = (row["status"]?.stringValue ?? "").lowercased()

            let title: String
            if let customTitle, !customTitle.isEmpty {
                title = customTitle
            } else if let rawTitle, !rawTitle.isEmpty {
                title = rawTitle
            } else if let cwd, !cwd.isEmpty {
                title = "WorkBuddy · \(URL(fileURLWithPath: cwd).lastPathComponent)"
            } else {
                title = "WorkBuddy 会话 \(sid.prefix(6))"
            }

            let tsMs = row["last_activity_at"]?.intValue ?? row["updated_at"]?.intValue ?? 0
            let modDate = tsMs > 0 ? Date(timeIntervalSince1970: Double(tsMs) / 1000.0) : now
            let ageSeconds = now.timeIntervalSince(modDate)

            let status: TaskStatus
            let message: String
            let provenLive: Bool

            if interruptedSessions.contains(sid) || dbStatus.contains("wait") || dbStatus.contains("interrupt") {
                status = .waitingUser
                message = "等待你确认或审批"
                provenLive = !isPriming || ageSeconds < 120
            } else if runningAutomations.contains(sid) || dbStatus == "running" || dbStatus == "in_progress" {
                status = .running
                message = "WorkBuddy 执行中"
                provenLive = !isPriming || runningAutomations.contains(sid) || ageSeconds < 120
            } else if dbStatus == "error" || dbStatus == "failed" {
                status = .error
                message = "任务执行失败"
                provenLive = false
            } else {
                status = .completed
                message = "本轮任务已完成"
                provenLive = false
            }

            let sig = "\(status.rawValue)|\(title)|\(tsMs)"
            emitIfChanged(
                sessionId: sid,
                signature: sig,
                status: status,
                title: title,
                message: message,
                cwd: cwd,
                modDate: modDate,
                isPriming: isPriming,
                provenLive: provenLive,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func fallbackScanSessionsJSON(isPriming: Bool, expectedGeneration: UInt64) {
        let sessionsDir = "\(rootDirectory)/sessions"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)

        for entry in entries where entry.hasSuffix(".json") {
            guard isCurrentGeneration(expectedGeneration) else { return }
            let path = "\(sessionsDir)/\(entry)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate >= cutoff,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let sid = (obj["sessionId"] as? String) ?? (obj["id"] as? String) ?? entry.replacingOccurrences(of: ".json", with: "")
            let cwd = obj["cwd"] as? String
            let pid = (obj["pid"] as? NSNumber)?.int32Value
            let title = (obj["title"] as? String) ?? (cwd.map { "WorkBuddy · \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "WorkBuddy \(sid)")
            let ageSeconds = Date().timeIntervalSince(modDate)
            let status: TaskStatus = ageSeconds < 60 ? .running : .completed
            let sig = "\(status.rawValue)|\(title)|\(Int(modDate.timeIntervalSince1970))"

            emitIfChanged(
                sessionId: sid,
                signature: sig,
                status: status,
                title: title,
                message: status == .running ? "WorkBuddy 会话活跃中" : "会话已结束",
                cwd: cwd,
                pid: pid,
                modDate: modDate,
                isPriming: isPriming,
                provenLive: !isPriming && status == .running,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func emitIfChanged(
        sessionId: String,
        signature: String,
        status: TaskStatus,
        title: String,
        message: String,
        cwd: String?,
        pid: Int32? = nil,
        modDate: Date,
        isPriming: Bool,
        provenLive: Bool,
        expectedGeneration: UInt64
    ) {
        lock.lock()
        guard lifecycleGeneration == expectedGeneration else {
            lock.unlock()
            return
        }
        if lastEmittedSignature[sessionId] == signature {
            lock.unlock()
            return
        }
        lastEmittedSignature[sessionId] = signature
        let handler = emitHandler
        lock.unlock()

        let event = TaskEvent(
            type: .upsert,
            source: .workbuddy,
            epoch: epoch,
            sessionId: sessionId,
            taskId: "main",
            seq: nextSeq(),
            status: status,
            title: title,
            message: message,
            appBundleId: "com.tencent.workbuddy.mac",
            cwd: cwd,
            pid: pid,
            isPriming: isPriming,
            provenLive: provenLive,
            timestamp: modDate
        )
        handler?(event)
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lifecycleGeneration
    }

    private func isCurrentGeneration(_ gen: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lifecycleGeneration == gen
    }

    private func setHealth(_ status: AdapterHealth) {
        lock.lock()
        _healthStatus = status
        lock.unlock()
    }

    private func nextSeq() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        seqCounter &+= 1
        if seqCounter == 0 { seqCounter = 1 }
        return seqCounter
    }
}
