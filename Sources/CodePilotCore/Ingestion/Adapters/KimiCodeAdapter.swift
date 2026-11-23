import Foundation

/// Read-only adapter for Kimi Code (`~/.kimi-code/session_index.jsonl` + `<sessionDir>/state.json`).
public final class KimiCodeAdapter: AgentAdapter, @unchecked Sendable {
    public let source: AgentSource = .kimiCode
    public let rootDirectory: String
    public let activeWindowSeconds: TimeInterval

    private let lock = NSLock()
    private var _healthStatus: AdapterHealth = .idle
    private var lifecycleGeneration: UInt64 = 0
    private let epoch: String
    private var seqCounter: UInt64 = 0
    private var fileFingerprints: [String: (mtime: TimeInterval, size: UInt64)] = [:]
    private let watcher: FSEventWatcher
    private let coalescer = AdapterRefreshCoalescer(delay: .milliseconds(300))
    private let workQueue = DispatchQueue(label: "com.codepilot.adapter.kimicode", qos: .utility)
    private var emitHandler: (@Sendable (TaskEvent) -> Void)?

    public var healthStatus: AdapterHealth {
        lock.lock()
        defer { lock.unlock() }
        return _healthStatus
    }

    public static var defaultRootDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.kimi-code"
    }

    public init(
        rootDirectory: String = KimiCodeAdapter.defaultRootDirectory,
        activeWindowSeconds: TimeInterval = 24 * 3600,
        epoch: String = "kimi-\(UUID().uuidString.prefix(8))"
    ) {
        self.rootDirectory = rootDirectory
        self.activeWindowSeconds = max(60, activeWindowSeconds)
        self.epoch = epoch
        self.watcher = FSEventWatcher(label: "com.codepilot.fsevents.kimicode")
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
        fileFingerprints.removeAll()
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
            self?.scanRecentSessions(isPriming: true, expectedGeneration: gen)
        }

        _ = watcher.start(paths: [rootDirectory], latency: 0.3) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                await self?.coalescer.schedule(key: "kimi_scan") { [weak self] in
                    self?.workQueue.async { [weak self] in
                        guard let self, self.isCurrentGeneration(gen) else { return }
                        self.scanRecentSessions(isPriming: false, expectedGeneration: gen)
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
        fileFingerprints.removeAll()
        _healthStatus = .idle
        lock.unlock()
    }

    /// Exposed for deterministic unit testing.
    public func scanOnce(isPriming: Bool = false) {
        scanRecentSessions(isPriming: isPriming, expectedGeneration: currentGeneration())
    }

    private func scanRecentSessions(isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        let indexPath = "\(rootDirectory)/session_index.jsonl"
        guard let raw = try? String(contentsOfFile: indexPath, encoding: .utf8) else { return }

        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)
        var seenSessions: [String: (sessionDir: String, workDir: String?)] = [:]

        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let sdir = obj["sessionDir"] as? String else {
                continue
            }
            seenSessions[sid] = (sdir, obj["workDir"] as? String)
        }

        let fm = FileManager.default
        for (sid, info) in seenSessions {
            guard isCurrentGeneration(expectedGeneration) else { return }
            let statePath = "\(info.sessionDir)/state.json"
            guard let attrs = try? fm.attributesOfItem(atPath: statePath),
                  let modDate = attrs[.modificationDate] as? Date,
                  let sizeNum = attrs[.size] as? NSNumber,
                  modDate >= cutoff else {
                continue
            }

            let fp = (mtime: modDate.timeIntervalSince1970, size: sizeNum.uint64Value)
            lock.lock()
            let prev = fileFingerprints[statePath]
            lock.unlock()
            if let prev, prev.mtime == fp.mtime && prev.size == fp.size {
                continue
            }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                  let event = parseStateJSON(data, sessionId: sid, fallbackWorkDir: info.workDir, modDate: modDate, isPriming: isPriming) else {
                continue
            }

            lock.lock()
            guard lifecycleGeneration == expectedGeneration else {
                lock.unlock()
                return
            }
            fileFingerprints[statePath] = fp
            let handler = emitHandler
            lock.unlock()
            handler?(event)
        }
    }

    private func parseStateJSON(
        _ data: Data,
        sessionId: String,
        fallbackWorkDir: String?,
        modDate: Date,
        isPriming: Bool
    ) -> TaskEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if (obj["archived"] as? Bool) == true {
            return nil
        }

        let cwd = (obj["cwd"] as? String) ?? fallbackWorkDir
        let lastTurnReason = (obj["lastTurnReason"] as? String)?.lowercased() ?? ""
        let explicitStatus = (obj["status"] as? String)?.lowercased() ?? ""
        let titleCandidate = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let title: String
        if let titleCandidate, !titleCandidate.isEmpty {
            title = titleCandidate
        } else if let cwd, !cwd.isEmpty {
            title = "Kimi · \(URL(fileURLWithPath: cwd).lastPathComponent)"
        } else {
            title = "Kimi 会话 \(sessionId.prefix(6))"
        }

        let ageSeconds = Date().timeIntervalSince(modDate)
        let status: TaskStatus
        let message: String
        let provenLive: Bool

        if explicitStatus.contains("wait") || explicitStatus.contains("approval") ||
            lastTurnReason.contains("approval") || lastTurnReason.contains("question") || lastTurnReason.contains("input") {
            status = .waitingUser
            message = "等待你确认或输入"
            provenLive = !isPriming || ageSeconds < 120
        } else if explicitStatus == "running" || lastTurnReason == "tool_use" || lastTurnReason == "running" ||
                    (lastTurnReason.isEmpty && ageSeconds < 90) {
            status = .running
            message = "Kimi Code 执行中"
            provenLive = !isPriming || ageSeconds < 90
        } else if explicitStatus == "error" || lastTurnReason == "error" || lastTurnReason == "aborted" {
            status = .error
            message = "执行异常或已中止"
            provenLive = false
        } else {
            status = .completed
            message = "本轮任务已完成"
            provenLive = false
        }

        return TaskEvent(
            type: .upsert,
            source: .kimiCode,
            epoch: epoch,
            sessionId: sessionId,
            taskId: "main",
            seq: nextSeq(),
            status: status,
            title: title,
            message: message,
            appBundleId: nil,
            cwd: cwd,
            isPriming: isPriming,
            provenLive: provenLive,
            timestamp: modDate
        )
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
