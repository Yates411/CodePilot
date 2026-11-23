import Foundation

/// Read-only adapter for Claude Code (`~/.claude/projects/**/*.jsonl`, ignoring `subagents`).
public final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    public let source: AgentSource = .claudeCode
    public let projectsDirectory: String
    public let activeWindowSeconds: TimeInterval

    private let lock = NSLock()
    private var _healthStatus: AdapterHealth = .idle
    private var lifecycleGeneration: UInt64 = 0
    private let epoch: String
    private var seqCounter: UInt64 = 0
    private var sessionTitles: [String: String] = [:]
    private var activeRunningSessions: Set<String> = []
    private let tailer: JSONLTailer
    private let watcher: FSEventWatcher
    private let coalescer = AdapterRefreshCoalescer(delay: .milliseconds(150))
    private let workQueue = DispatchQueue(label: "com.codepilot.adapter.claudecode", qos: .utility)
    private var emitHandler: (@Sendable (TaskEvent) -> Void)?

    public var healthStatus: AdapterHealth {
        lock.lock()
        defer { lock.unlock() }
        return _healthStatus
    }

    public static var defaultProjectsDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects"
    }

    public init(
        projectsDirectory: String = ClaudeCodeAdapter.defaultProjectsDirectory,
        activeWindowSeconds: TimeInterval = 24 * 3600,
        epoch: String = "claude-\(UUID().uuidString.prefix(8))"
    ) {
        self.projectsDirectory = projectsDirectory
        self.activeWindowSeconds = max(60, activeWindowSeconds)
        self.epoch = epoch
        self.tailer = JSONLTailer()
        self.watcher = FSEventWatcher(label: "com.codepilot.fsevents.claudecode")
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
        sessionTitles.removeAll()
        activeRunningSessions.removeAll()
        lock.unlock()
        tailer.resetAll()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsDirectory, isDirectory: &isDir), isDir.boolValue else {
            setHealth(.notInstalled)
            return
        }

        setHealth(.active(watchedPath: projectsDirectory))

        workQueue.async { [weak self] in
            self?.scanRecentSessions(isPriming: true, expectedGeneration: gen)
        }

        _ = watcher.start(paths: [projectsDirectory], latency: 0.1) { [weak self] changedPaths in
            guard let self else { return }
            let files = Set(changedPaths.filter { $0.hasSuffix(".jsonl") && !$0.contains("/subagents/") })
            let targets = files.isEmpty ? ["__scan_all__"] : Array(files)
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
        sessionTitles.removeAll()
        activeRunningSessions.removeAll()
        _healthStatus = .idle
        lock.unlock()
        tailer.resetAll()
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
        processSessionFile(at: path, isPriming: isPriming, expectedGeneration: currentGeneration())
    }

    private func scanRecentSessions(isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectsDirectory) else { return }
        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)

        while let rel = enumerator.nextObject() as? String {
            guard isCurrentGeneration(expectedGeneration) else { return }
            guard rel.hasSuffix(".jsonl"), !rel.contains("/subagents/") else { continue }
            let fullPath = "\(projectsDirectory)/\(rel)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate >= cutoff else {
                continue
            }
            processSessionFile(at: fullPath, isPriming: isPriming, expectedGeneration: expectedGeneration)
        }
    }

    private func processSessionFile(at path: String, isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        let lines = tailer.readNewLines(at: path)
        let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let modDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        let ageSeconds = Date().timeIntervalSince(modDate)

        if lines.isEmpty {
            if ageSeconds >= 180 {
                lock.lock()
                let wasRunning = activeRunningSessions.remove(sessionId) != nil
                let title = sessionTitles[sessionId] ?? "Claude 会话 \(sessionId.prefix(6))"
                let validGen = (lifecycleGeneration == expectedGeneration)
                let handler = emitHandler
                lock.unlock()
                if wasRunning && validGen {
                    let archived = TaskEvent(
                        type: .upsert,
                        source: .claudeCode,
                        epoch: epoch,
                        sessionId: sessionId,
                        taskId: "main",
                        seq: nextSeq(),
                        status: .completed,
                        title: title,
                        message: "会话已静默归档",
                        appBundleId: nil,
                        deepLinkURL: "claude://code/continue?session=\(sessionId)",
                        isPriming: isPriming,
                        provenLive: false,
                        timestamp: modDate
                    )
                    handler?(archived)
                }
            }
            return
        }

        var latestStatus: TaskStatus?
        var latestMessage: String?
        var cwd: String?

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let c = obj["cwd"] as? String { cwd = c }

            let role = (obj["type"] as? String)?.lowercased() ?? ""
            let messageObj = obj["message"] as? [String: Any]
            let stopReason = (messageObj?["stop_reason"] as? String)?.lowercased() ?? ""

            if role == "user" {
                if let contentStr = messageObj?["content"] as? String {
                    let trimmed = contentStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("/") {
                        let short = trimmed.count > 42 ? String(trimmed.prefix(41)) + "…" : trimmed
                        lock.lock()
                        if sessionTitles[sessionId] == nil {
                            sessionTitles[sessionId] = short
                        }
                        lock.unlock()
                        latestStatus = .running
                        latestMessage = "Claude Code 处理中"
                    }
                } else {
                    latestStatus = .running
                    latestMessage = "Claude Code 处理中"
                }
            } else if role == "assistant" {
                let blocks = messageObj?["content"] as? [[String: Any]] ?? []
                let hasUserPromptTool = blocks.contains { block in
                    guard (block["type"] as? String) == "tool_use",
                          let name = block["name"] as? String else { return false }
                    return name == "AskUserQuestion" || name == "ExitPlanMode"
                }

                if hasUserPromptTool {
                    latestStatus = .waitingUser
                    latestMessage = "等待你确认计划或回答问题"
                } else if stopReason == "tool_use" || stopReason == "pause_turn" {
                    latestStatus = .running
                    latestMessage = "正在执行工具调用"
                } else if stopReason == "end_turn" || stopReason == "stop_sequence" || stopReason == "max_tokens" {
                    latestStatus = .completed
                    latestMessage = "本轮任务已完成"
                }
            }
        }

        guard var status = latestStatus else { return }

        if status == .running && ageSeconds >= 180 {
            status = .completed
            latestMessage = "历史会话已归档"
        }

        lock.lock()
        guard lifecycleGeneration == expectedGeneration else {
            lock.unlock()
            return
        }
        if status == .running {
            activeRunningSessions.insert(sessionId)
        } else {
            activeRunningSessions.remove(sessionId)
        }
        let title = sessionTitles[sessionId] ?? (cwd.map { "Claude · \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Claude 会话 \(sessionId.prefix(6))")
        let handler = emitHandler
        lock.unlock()

        let provenLive: Bool
        if status == .running {
            provenLive = !isPriming || ageSeconds < 120
        } else {
            provenLive = !isPriming
        }

        let event = TaskEvent(
            type: .upsert,
            source: .claudeCode,
            epoch: epoch,
            sessionId: sessionId,
            taskId: "main",
            seq: nextSeq(),
            status: status,
            title: title,
            message: latestMessage,
            appBundleId: nil,
            deepLinkURL: "claude://code/continue?session=\(sessionId)",
            cwd: cwd,
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
