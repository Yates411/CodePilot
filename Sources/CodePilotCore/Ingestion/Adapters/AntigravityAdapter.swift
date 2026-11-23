import Foundation

/// Read-only adapter for Antigravity local transcript logs:
/// `~/.gemini/antigravity/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`
public final class AntigravityAdapter: AgentAdapter, @unchecked Sendable {
    public let source: AgentSource = .antigravity
    public let brainDirectory: String
    public let activeWindowSeconds: TimeInterval

    private let lock = NSLock()
    private var _healthStatus: AdapterHealth = .idle
    private var lifecycleGeneration: UInt64 = 0
    private let epoch: String
    private var seqCounter: UInt64 = 0
    private var sessionTitles: [String: String] = [:]
    private let tailer: JSONLTailer
    private let watcher: FSEventWatcher
    private let coalescer = AdapterRefreshCoalescer(delay: .milliseconds(250))
    private let workQueue = DispatchQueue(label: "com.codepilot.adapter.antigravity", qos: .utility)
    private var emitHandler: (@Sendable (TaskEvent) -> Void)?

    public var healthStatus: AdapterHealth {
        lock.lock()
        defer { lock.unlock() }
        return _healthStatus
    }

    public static var defaultBrainDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.gemini/antigravity/brain"
    }

    public init(
        brainDirectory: String = AntigravityAdapter.defaultBrainDirectory,
        activeWindowSeconds: TimeInterval = 24 * 3600,
        epoch: String = "ag-\(UUID().uuidString.prefix(8))"
    ) {
        self.brainDirectory = brainDirectory
        self.activeWindowSeconds = max(60, activeWindowSeconds)
        self.epoch = epoch
        self.tailer = JSONLTailer()
        self.watcher = FSEventWatcher(label: "com.codepilot.fsevents.antigravity")
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
        lock.unlock()
        tailer.resetAll()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: brainDirectory, isDirectory: &isDir), isDir.boolValue else {
            setHealth(.notInstalled)
            return
        }

        do {
            _ = try fm.contentsOfDirectory(atPath: brainDirectory)
        } catch let err as NSError {
            if err.domain == NSCocoaErrorDomain && err.code == NSFileReadNoPermissionError ||
                err.domain == NSPOSIXErrorDomain && err.code == Int(EPERM) {
                setHealth(.permissionDenied(path: brainDirectory))
            } else {
                setHealth(.error(err.localizedDescription))
            }
            return
        }

        setHealth(.active(watchedPath: brainDirectory))

        workQueue.async { [weak self] in
            self?.scanRecentTranscripts(isPriming: true, expectedGeneration: gen)
        }

        _ = watcher.start(paths: [brainDirectory], latency: 0.3) { [weak self] changedPaths in
            guard let self else { return }
            var transcriptFiles = Set<String>()
            for rawPath in changedPaths {
                if rawPath.hasSuffix("/transcript.jsonl") {
                    transcriptFiles.insert(rawPath)
                } else if let conversationId = Self.extractConversationId(from: rawPath, brainDir: self.brainDirectory) {
                    let candidate = "\(self.brainDirectory)/\(conversationId)/.system_generated/logs/transcript.jsonl"
                    if FileManager.default.fileExists(atPath: candidate) {
                        transcriptFiles.insert(candidate)
                    }
                }
            }
            for file in transcriptFiles {
                Task { [weak self] in
                    await self?.coalescer.schedule(key: file) { [weak self] in
                        self?.workQueue.async { [weak self] in
                            guard let self, self.isCurrentGeneration(gen) else { return }
                            self.processTranscriptFile(at: file, isPriming: false, expectedGeneration: gen)
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
        _healthStatus = .idle
        lock.unlock()
        tailer.resetAll()
    }

    /// Exposed for deterministic unit testing without waiting on FSEvents.
    public func processTranscriptFile(at path: String, isPriming: Bool = false) {
        let gen = currentGeneration()
        processTranscriptFile(at: path, isPriming: isPriming, expectedGeneration: gen)
    }

    private func processTranscriptFile(at path: String, isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        guard let conversationId = Self.extractConversationId(from: path, brainDir: brainDirectory) else {
            return
        }
        let lines = tailer.readNewLines(at: path)
        guard !lines.isEmpty else { return }

        let modDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        let ageSeconds = Date().timeIntervalSince(modDate)

        var latestEvent: TaskEvent?
        for line in lines {
            if let parsed = parseTranscriptLine(
                line,
                conversationId: conversationId,
                modDate: modDate,
                ageSeconds: ageSeconds,
                isPriming: isPriming
            ) {
                latestEvent = parsed
            }
        }

        if let event = latestEvent {
            lock.lock()
            guard lifecycleGeneration == expectedGeneration else {
                lock.unlock()
                return
            }
            let handler = emitHandler
            lock.unlock()
            handler?(event)
        }
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

    private func scanRecentTranscripts(isPriming: Bool, expectedGeneration: UInt64) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: brainDirectory) else { return }
        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)

        for entry in entries where !entry.hasPrefix(".") {
            guard isCurrentGeneration(expectedGeneration) else { return }
            let transcriptPath = "\(brainDirectory)/\(entry)/.system_generated/logs/transcript.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: transcriptPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate >= cutoff else {
                continue
            }
            processTranscriptFile(at: transcriptPath, isPriming: isPriming, expectedGeneration: expectedGeneration)
        }
    }

    private func parseTranscriptLine(
        _ data: Data,
        conversationId: String,
        modDate: Date,
        ageSeconds: TimeInterval,
        isPriming: Bool
    ) -> TaskEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stepType = obj["type"] as? String else {
            return nil
        }

        let statusStr = (obj["status"] as? String)?.uppercased() ?? ""
        let content = obj["content"] as? String
        let toolCalls = obj["tool_calls"] as? [[String: Any]] ?? []

        if stepType == "USER_INPUT", let content, !content.isEmpty {
            if let cleanedTitle = TitleSanitizer.clean(content, maxLength: 42) {
                lock.lock()
                if sessionTitles[conversationId] == nil {
                    sessionTitles[conversationId] = cleanedTitle
                }
                lock.unlock()
            }
        }

        lock.lock()
        let title = sessionTitles[conversationId] ?? "Antigravity 会话 \(conversationId.prefix(6))"
        lock.unlock()

        var mappedStatus: TaskStatus
        var message: String?

        switch stepType {
        case "USER_INPUT":
            mappedStatus = .running
            message = "处理用户请求中"
        case "GENERIC":
            if statusStr == "ERROR" {
                mappedStatus = .error
                message = "步骤执行异常"
            } else if statusStr.contains("WAIT") || statusStr.contains("PENDING") || statusStr.contains("APPROV") {
                mappedStatus = .waitingUser
                message = "等待你批准或确认操作"
            } else {
                mappedStatus = .running
                message = "工具执行中"
            }
        case "PLANNER_RESPONSE":
            if statusStr == "ERROR" {
                mappedStatus = .error
                message = "执行异常"
            } else if statusStr.contains("WAIT") || statusStr.contains("PENDING") || statusStr.contains("APPROV") {
                mappedStatus = .waitingUser
                message = "等待你确认或批准操作"
            } else if !toolCalls.isEmpty {
                if let waitingReason = Self.detectWaitingUserReason(in: toolCalls) {
                    mappedStatus = .waitingUser
                    message = waitingReason
                } else {
                    mappedStatus = .running
                    message = "正在执行工具调用"
                }
            } else if statusStr == "DONE" {
                mappedStatus = .completed
                message = "本轮回复已完成"
            } else {
                mappedStatus = .running
            }
        default:
            return nil
        }

        // Prevent stale historical sessions (>10 min without writes) from showing as stuck "running".
        if mappedStatus == .running && ageSeconds >= 600 {
            mappedStatus = .completed
            message = "历史会话已归档"
        }

        let provenLive: Bool
        if mappedStatus == .running {
            provenLive = !isPriming || ageSeconds < 90
        } else {
            provenLive = !isPriming
        }

        return TaskEvent(
            type: .upsert,
            source: .antigravity,
            epoch: epoch,
            sessionId: conversationId,
            taskId: "main",
            seq: nextSeq(),
            status: mappedStatus,
            title: title,
            message: message,
            appBundleId: "com.google.antigravity",
            isPriming: isPriming,
            provenLive: provenLive,
            timestamp: modDate
        )
    }

    public static func detectWaitingUserReason(in toolCalls: [[String: Any]]) -> String? {
        for call in toolCalls {
            let name = ((call["name"] as? String) ?? (call["tool_name"] as? String) ?? "").lowercased()
            if name == "ask_question" {
                return "等待你确认或回答问题"
            }

            let rawArgs = call["arguments"] ?? call["args"]
            if name == "run_command", Self.containsTruthyFlag(rawArgs, key: "BypassSandbox") {
                return "请求授权执行命令（BypassSandbox）"
            }

            if (name == "write_file" || name == "edit_file"),
               Self.containsTruthyFlag(rawArgs, key: "RequestFeedback") {
                return "等待你审阅并批准计划"
            }
        }
        return nil
    }

    private static func containsTruthyFlag(_ value: Any?, key: String) -> Bool {
        guard let value else { return false }
        if let dict = value as? [String: Any] {
            if let boolVal = dict[key] as? Bool, boolVal {
                return true
            }
            if let strVal = dict[key] as? String, strVal.lowercased() == "true" {
                return true
            }
            for nested in dict.values {
                if containsTruthyFlag(nested, key: key) {
                    return true
                }
            }
            return false
        }
        if let str = value as? String {
            let compact = str.replacingOccurrences(of: " ", with: "")
            if compact.contains("\"\(key)\":true") || compact.contains("\\\"\(key)\\\":true") {
                return true
            }
            if let data = str.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                return containsTruthyFlag(parsed, key: key)
            }
        }
        return false
    }

    public static func extractConversationId(from path: String, brainDir: String) -> String? {
        let normalizedBrain = brainDir.hasSuffix("/") ? brainDir : brainDir + "/"
        guard path.hasPrefix(normalizedBrain) else { return nil }
        let remainder = path.dropFirst(normalizedBrain.count)
        guard let firstComponent = remainder.split(separator: "/").first, !firstComponent.isEmpty else {
            return nil
        }
        return String(firstComponent)
    }
}
