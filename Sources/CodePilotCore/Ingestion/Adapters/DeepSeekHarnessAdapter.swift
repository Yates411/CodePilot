import Foundation

/// Read-only, zero-intrusion adapter for DeepSeek Harness projection cache:
/// `~/.dsh/storages/session_projcache/sessions/session-*.json`
public final class DeepSeekHarnessAdapter: AgentAdapter, @unchecked Sendable {
    public let source: AgentSource = .deepseekHarness
    public let projCacheDirectory: String
    public let activeWindowSeconds: TimeInterval

    private let lock = NSLock()
    private var _healthStatus: AdapterHealth = .idle
    private var lifecycleGeneration: UInt64 = 0
    private let epoch: String
    private var seqCounter: UInt64 = 0
    private var fileFingerprints: [String: (mtime: TimeInterval, size: UInt64)] = [:]
    private var activeRunningPaths: Set<String> = []
    private let watcher: FSEventWatcher
    private let coalescer = AdapterRefreshCoalescer(delay: .milliseconds(120))
    private let workQueue = DispatchQueue(label: "com.codepilot.adapter.dsh", qos: .utility)
    private var emitHandler: (@Sendable (TaskEvent) -> Void)?

    public var healthStatus: AdapterHealth {
        lock.lock()
        defer { lock.unlock() }
        return _healthStatus
    }

    public static var defaultProjCacheDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.dsh/storages/session_projcache/sessions"
    }

    public init(
        projCacheDirectory: String = DeepSeekHarnessAdapter.defaultProjCacheDirectory,
        activeWindowSeconds: TimeInterval = 24 * 3600,
        epoch: String = "dsh-\(UUID().uuidString.prefix(8))"
    ) {
        self.projCacheDirectory = projCacheDirectory
        self.activeWindowSeconds = max(60, activeWindowSeconds)
        self.epoch = epoch
        self.watcher = FSEventWatcher(label: "com.codepilot.fsevents.dsh")
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
        activeRunningPaths.removeAll()
        lock.unlock()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projCacheDirectory, isDirectory: &isDir), isDir.boolValue else {
            setHealth(.notInstalled)
            return
        }

        do {
            _ = try fm.contentsOfDirectory(atPath: projCacheDirectory)
        } catch let err as NSError {
            if err.domain == NSCocoaErrorDomain && err.code == NSFileReadNoPermissionError ||
                err.domain == NSPOSIXErrorDomain && err.code == Int(EPERM) {
                setHealth(.permissionDenied(path: projCacheDirectory))
            } else {
                setHealth(.error(err.localizedDescription))
            }
            return
        }

        setHealth(.active(watchedPath: projCacheDirectory))

        workQueue.async { [weak self] in
            self?.scanRecentSessions(isPriming: true, expectedGeneration: gen)
        }

        _ = watcher.start(paths: [projCacheDirectory], latency: 0.1) { [weak self] changedPaths in
            guard let self else { return }
            let jsonFiles = Set(changedPaths.filter {
                $0.hasSuffix(".json") && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("session-")
            })
            let targets = jsonFiles.isEmpty ? ["__scan_all__"] : Array(jsonFiles)
            for target in targets {
                Task { [weak self] in
                    await self?.coalescer.schedule(key: target) { [weak self] in
                        self?.workQueue.async { [weak self] in
                            guard let self, self.isCurrentGeneration(gen) else { return }
                            if target == "__scan_all__" {
                                self.scanRecentSessions(isPriming: false, expectedGeneration: gen)
                            } else {
                                self.processSessionFile(at: target, isPriming: false, expectedGeneration: gen)
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
        fileFingerprints.removeAll()
        activeRunningPaths.removeAll()
        _healthStatus = .idle
        lock.unlock()
    }

    public func pollIfNeeded() {
        let gen = currentGeneration()
        guard case .active = healthStatus else { return }
        workQueue.async { [weak self] in
            self?.scanRecentSessions(isPriming: false, expectedGeneration: gen)
        }
    }

    /// Exposed for deterministic unit testing.
    public func processSessionFile(at path: String, isPriming: Bool = false) {
        let gen = currentGeneration()
        processSessionFile(at: path, isPriming: isPriming, expectedGeneration: gen)
    }

    private func processSessionFile(at path: String, isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }

        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              let sizeNum = attrs[.size] as? NSNumber else {
            return
        }

        let fp = (mtime: modDate.timeIntervalSince1970, size: sizeNum.uint64Value)
        let ageSeconds = Date().timeIntervalSince(modDate)
        lock.lock()
        let prev = fileFingerprints[path]
        let wasRunning = activeRunningPaths.contains(path)
        lock.unlock()
        if let prev, prev.mtime == fp.mtime && prev.size == fp.size {
            if !(wasRunning && ageSeconds >= 180) {
                return
            }
        }

        var parsedEvent: TaskEvent?
        if let firstTry = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            parsedEvent = parseSessionJSON(firstTry, path: path, modDate: modDate, isPriming: isPriming)
        }
        if parsedEvent == nil {
            Thread.sleep(forTimeInterval: 0.15)
            guard isCurrentGeneration(expectedGeneration) else { return }
            if let retryData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                parsedEvent = parseSessionJSON(retryData, path: path, modDate: modDate, isPriming: isPriming)
            }
        }

        guard let event = parsedEvent else {
            // Do not record fingerprint on parse failure so subsequent reads can retry.
            return
        }

        // Commit fingerprint and emit only if still in the same lifecycle generation.
        lock.lock()
        guard lifecycleGeneration == expectedGeneration else {
            lock.unlock()
            return
        }
        fileFingerprints[path] = fp
        if event.status == .running {
            activeRunningPaths.insert(path)
        } else {
            activeRunningPaths.remove(path)
        }
        let handler = emitHandler
        lock.unlock()

        handler?(event)
    }

    private func scanRecentSessions(isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projCacheDirectory) else { return }
        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)

        for entry in entries where entry.hasPrefix("session-") && entry.hasSuffix(".json") {
            guard isCurrentGeneration(expectedGeneration) else { return }
            let fullPath = "\(projCacheDirectory)/\(entry)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate >= cutoff else {
                continue
            }
            processSessionFile(at: fullPath, isPriming: isPriming, expectedGeneration: expectedGeneration)
        }
    }

    private func parseSessionJSON(_ data: Data, path: String, modDate: Date, isPriming: Bool) -> TaskEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else {
            return nil
        }

        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let sessionId = fileName.hasPrefix("session-") ? String(fileName.dropFirst("session-".count)) : fileName

        let identity = record["identity"] as? [String: Any]
        let cwd = identity?["cwd"] as? String

        let titleRow = rows["title"] as? [String: Any]
        let rawTitle = (titleRow?["val"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let rawTitle, !rawTitle.isEmpty {
            title = rawTitle
        } else if let cwd, !cwd.isEmpty {
            title = "DSH · \(URL(fileURLWithPath: cwd).lastPathComponent)"
        } else {
            title = "DeepSeek 会话 \(sessionId.prefix(6))"
        }

        let uqRow = rows["userQuestions"] as? [String: Any]
        let uqVal = uqRow?["val"] as? [String: Any]
        let questionsObj = uqVal?["questions"] as? [String: Any]
        let activeQuestions = questionsObj?["active"] as? [Any] ?? []

        let tbRow = rows["turnBoundary"] as? [String: Any]
        let tbVal = tbRow?["val"] as? [String: Any]
        let openTurnStartSeq = tbVal?["openTurnStartSeq"]
        let isOpenTurn = (openTurnStartSeq != nil && !(openTurnStartSeq is NSNull))

        let approvalRow = rows["approvalState"] as? [String: Any]
        let approvalVal = approvalRow?["val"] as? [String: Any]
        let turnOpen = (approvalVal?["turnOpen"] as? Bool) ?? false

        let lastStepBoundary = tbVal?["lastStepBoundary"] as? [String: Any]
        let boundaryKind = (lastStepBoundary?["kind"] as? String)?.lowercased() ?? ""

        let rowSeq = (tbRow?["seq"] as? NSNumber)?.uint64Value ?? 0
        let ageSeconds = Date().timeIntervalSince(modDate)

        let status: TaskStatus
        var message: String?
        let provenLive: Bool

        if !activeQuestions.isEmpty {
            status = .waitingUser
            message = "有 \(activeQuestions.count) 个问题等待你回复"
            provenLive = !isPriming || ageSeconds < 120
        } else if isOpenTurn || turnOpen {
            if ageSeconds >= 180 {
                status = .completed
                message = "历史会话已归档"
                provenLive = false
            } else {
                status = .running
                message = "DeepSeek Harness 执行中"
                provenLive = !isPriming || ageSeconds < 120
            }
        } else if boundaryKind == "error" || boundaryKind == "aborted" {
            status = .error
            message = "任务异常中止"
            provenLive = false
        } else {
            status = .completed
            message = "本轮任务已完成"
            provenLive = false
        }

        let seq = max(nextSeq(), rowSeq)
        return TaskEvent(
            type: .upsert,
            source: .deepseekHarness,
            epoch: epoch,
            sessionId: sessionId,
            taskId: "main",
            seq: seq,
            status: status,
            title: title,
            message: message,
            appBundleId: "com.deepseek.dsh",
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
