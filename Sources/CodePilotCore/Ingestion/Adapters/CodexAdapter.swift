import Foundation

/// Read-only adapter for OpenAI Codex (`~/.codex/sessions/**/rollout-*.jsonl` + `state_5.sqlite`).
public final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    public let source: AgentSource = .codex
    public let rootDirectory: String
    public let activeWindowSeconds: TimeInterval

    private let lock = NSLock()
    private var _healthStatus: AdapterHealth = .idle
    private var lifecycleGeneration: UInt64 = 0
    private let epoch: String
    private var seqCounter: UInt64 = 0
    private var threadTitles: [String: (title: String, cwd: String?)] = [:]
    private var activeRunningSessions: Set<String> = []
    private var lastTitleRefresh: Date = .distantPast
    private let tailer: JSONLTailer
    private let watcher: FSEventWatcher
    private let coalescer = AdapterRefreshCoalescer(delay: .milliseconds(150))
    private let workQueue = DispatchQueue(label: "com.codepilot.adapter.codex", qos: .utility)
    private var emitHandler: (@Sendable (TaskEvent) -> Void)?

    public var healthStatus: AdapterHealth {
        lock.lock()
        defer { lock.unlock() }
        return _healthStatus
    }

    public static var defaultRootDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex"
    }

    public init(
        rootDirectory: String = CodexAdapter.defaultRootDirectory,
        activeWindowSeconds: TimeInterval = 24 * 3600,
        epoch: String = "codex-\(UUID().uuidString.prefix(8))"
    ) {
        self.rootDirectory = rootDirectory
        self.activeWindowSeconds = max(60, activeWindowSeconds)
        self.epoch = epoch
        self.tailer = JSONLTailer()
        self.watcher = FSEventWatcher(label: "com.codepilot.fsevents.codex")
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
        threadTitles.removeAll()
        activeRunningSessions.removeAll()
        lastTitleRefresh = .distantPast
        lock.unlock()
        tailer.resetAll()

        let sessionsDir = "\(rootDirectory)/sessions"
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir, isDirectory: &isDir), isDir.boolValue else {
            setHealth(.notInstalled)
            return
        }

        setHealth(.active(watchedPath: sessionsDir))

        workQueue.async { [weak self] in
            self?.refreshThreadTitlesIfNeeded()
            self?.scanRecentRollouts(isPriming: true, expectedGeneration: gen)
        }

        _ = watcher.start(paths: [sessionsDir], latency: 0.1) { [weak self] changedPaths in
            guard let self else { return }
            let rollouts = Set(changedPaths.filter { $0.hasSuffix(".jsonl") && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("rollout-") })
            let targets = rollouts.isEmpty ? ["__scan_all__"] : Array(rollouts)
            for target in targets {
                Task { [weak self] in
                    await self?.coalescer.schedule(key: target) { [weak self] in
                        self?.workQueue.async { [weak self] in
                            guard let self, self.isCurrentGeneration(gen) else { return }
                            self.refreshThreadTitlesIfNeeded()
                            if target == "__scan_all__" {
                                self.scanRecentRollouts(isPriming: false, expectedGeneration: gen)
                            } else {
                                self.processRolloutFile(at: target, isPriming: false, expectedGeneration: gen)
                            }
                        }
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
        threadTitles.removeAll()
        activeRunningSessions.removeAll()
        _healthStatus = .idle
        lock.unlock()
        tailer.resetAll()
    }

    public func pollIfNeeded() {
        let gen = currentGeneration()
        guard case .active = healthStatus else { return }
        workQueue.async { [weak self] in
            self?.refreshThreadTitlesIfNeeded()
            self?.scanRecentRollouts(isPriming: false, expectedGeneration: gen)
        }
    }

    /// Exposed for deterministic unit testing.
    public func processRolloutFile(at path: String, isPriming: Bool = false) {
        refreshThreadTitlesIfNeeded()
        processRolloutFile(at: path, isPriming: isPriming, expectedGeneration: currentGeneration())
    }

    private func refreshThreadTitlesIfNeeded() {
        lock.lock()
        let shouldRefresh = Date().timeIntervalSince(lastTitleRefresh) >= 30
        lock.unlock()
        guard shouldRefresh else { return }

        let dbPath = "\(rootDirectory)/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        let db = ReadOnlySQLite(path: dbPath, busyTimeoutMs: 200)
        guard let rows = try? db.query("SELECT id, title, cwd FROM threads ORDER BY updated_at DESC LIMIT 100") else {
            return
        }

        var map: [String: (title: String, cwd: String?)] = [:]
        for r in rows {
            if let id = r["id"]?.stringValue,
               let title = r["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                map[id] = (title, r["cwd"]?.stringValue)
            }
        }

        lock.lock()
        threadTitles = map
        lastTitleRefresh = Date()
        lock.unlock()
    }

    private func scanRecentRollouts(isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        let sessionsDir = "\(rootDirectory)/sessions"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: sessionsDir) else { return }
        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)

        while let rel = enumerator.nextObject() as? String {
            guard isCurrentGeneration(expectedGeneration) else { return }
            guard rel.hasSuffix(".jsonl"), URL(fileURLWithPath: rel).lastPathComponent.hasPrefix("rollout-") else {
                continue
            }
            let fullPath = "\(sessionsDir)/\(rel)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate >= cutoff else {
                continue
            }
            processRolloutFile(at: fullPath, isPriming: isPriming, expectedGeneration: expectedGeneration)
        }
    }

    private func processRolloutFile(at path: String, isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        let lines = tailer.readNewLines(at: path)
        let modDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        let ageSeconds = Date().timeIntervalSince(modDate)

        if lines.isEmpty {
            let sid = Self.extractThreadId(from: path)
            if ageSeconds >= 180 {
                lock.lock()
                let wasRunning = activeRunningSessions.remove(sid) != nil
                let cached = threadTitles[sid]
                let validGen = (lifecycleGeneration == expectedGeneration)
                let handler = emitHandler
                lock.unlock()
                if wasRunning && validGen {
                    let title = TitleSanitizer.clean(cached?.title, maxLength: 42)
                        ?? (cached?.cwd.map { "Codex · \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Codex 会话 \(sid.prefix(6))")
                    let archived = TaskEvent(
                        type: .upsert,
                        source: .codex,
                        epoch: epoch,
                        sessionId: sid,
                        taskId: "main",
                        seq: nextSeq(),
                        status: .completed,
                        title: title,
                        message: "会话已静默归档",
                        appBundleId: nil,
                        deepLinkURL: "codex://threads/\(sid)",
                        cwd: cached?.cwd,
                        isPriming: isPriming,
                        provenLive: false,
                        timestamp: modDate
                    )
                    handler?(archived)
                }
            }
            return
        }

        var sessionId = Self.extractThreadId(from: path)
        var cwd: String?
        var isSubagent = false
        var latestStatus: TaskStatus?
        var latestMessage: String?

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let recordType = obj["type"] as? String else {
                continue
            }

            if recordType == "session_meta", let payload = obj["payload"] as? [String: Any] {
                if let id = payload["id"] as? String, !id.isEmpty {
                    sessionId = id
                }
                if let dir = payload["cwd"] as? String {
                    cwd = dir
                }
                if let src = payload["source"] as? String,
                   src.lowercased().contains("subagent") || src.lowercased().contains("guardian") {
                    isSubagent = true
                }
            } else if recordType == "event_msg", let payload = obj["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String {
                switch eventType {
                case "task_started":
                    latestStatus = .running
                    latestMessage = "Codex 执行中"
                case "task_complete":
                    latestStatus = .completed
                    latestMessage = "本轮任务已完成"
                case "turn_aborted":
                    latestStatus = .error
                    latestMessage = "任务已中止"
                case "request_user_input":
                    latestStatus = .waitingUser
                    latestMessage = "等待你输入回复"
                default:
                    if eventType.hasSuffix("approval_request") {
                        latestStatus = .waitingUser
                        latestMessage = "等待你批准操作"
                    }
                }
            }
        }

        guard !isSubagent, var status = latestStatus else { return }

        lock.lock()
        let cached = threadTitles[sessionId]
        guard lifecycleGeneration == expectedGeneration else {
            lock.unlock()
            return
        }
        let handler = emitHandler
        lock.unlock()

        // Filter out internal automated review/bridge prompts so they don't clutter user tasks.
        if TitleSanitizer.isInternalBridgePrompt(cached?.title) {
            return
        }

        if status == .running && ageSeconds >= 180 {
            status = .completed
            latestMessage = "历史会话已归档"
        }

        lock.lock()
        if status == .running {
            activeRunningSessions.insert(sessionId)
        } else {
            activeRunningSessions.remove(sessionId)
        }
        lock.unlock()

        let resolvedCwd = cwd ?? cached?.cwd
        let title: String
        if let cleaned = TitleSanitizer.clean(cached?.title, maxLength: 42) {
            title = cleaned
        } else if let resolvedCwd, !resolvedCwd.isEmpty {
            title = "Codex · \(URL(fileURLWithPath: resolvedCwd).lastPathComponent)"
        } else {
            title = "Codex 会话 \(sessionId.prefix(6))"
        }

        let provenLive: Bool
        if status == .running {
            provenLive = !isPriming || ageSeconds < 120
        } else {
            provenLive = !isPriming
        }

        let deepLink = "codex://threads/\(sessionId)"
        let event = TaskEvent(
            type: .upsert,
            source: .codex,
            epoch: epoch,
            sessionId: sessionId,
            taskId: "main",
            seq: nextSeq(),
            status: status,
            title: title,
            message: latestMessage,
            appBundleId: nil,
            deepLinkURL: deepLink,
            cwd: resolvedCwd,
            isPriming: isPriming,
            provenLive: provenLive,
            timestamp: modDate
        )
        handler?(event)
    }

    public static func extractThreadId(from path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // Typical format: rollout-2026-11-23T19-00-00-<uuid>
        let parts = name.split(separator: "-")
        if parts.count >= 6 {
            return parts.suffix(5).joined(separator: "-")
        }
        return name
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
