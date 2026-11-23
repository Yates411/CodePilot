import Foundation

public enum AgentSource: String, Codable, Hashable, CaseIterable, Sendable {
    case antigravity
    case kimiCode = "kimi_code"
    case workbuddy
    case codex
    case deepseekHarness = "deepseek_harness"
    case claudeCode = "claude_code"
    case custom

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .kimiCode: return "Kimi Code"
        case .workbuddy: return "WorkBuddy"
        case .codex: return "Codex"
        case .deepseekHarness: return "DeepSeek Harness"
        case .claudeCode: return "Claude Code"
        case .custom: return "Custom"
        }
    }
}

public struct TaskKey: Hashable, Codable, Sendable {
    public let source: AgentSource
    public let sessionId: String
    public let taskId: String

    public init(source: AgentSource, sessionId: String, taskId: String) {
        self.source = source
        self.sessionId = sessionId
        self.taskId = taskId
    }
}

public enum TaskStatus: String, Codable, Hashable, Sendable {
    case running
    case waitingUser = "waiting_user"
    case completed
    case error

    public var sortPriority: Int {
        switch self {
        case .waitingUser: return 0
        case .running: return 1
        case .error: return 2
        case .completed: return 3
        }
    }

    public var isFinished: Bool {
        self == .completed || self == .error
    }
}

public enum TaskEventType: String, Codable, Sendable {
    case upsert
    case heartbeat
    case remove
}

public enum ReadAckLevel: Equatable, Sendable {
    case seenByApp(AgentSource)
    case openedSession(TaskKey)
    case userConfirmed(TaskKey)
}

public struct TaskEvent: Codable, Sendable, Equatable {
    public let type: TaskEventType
    public let source: AgentSource
    public let epoch: String
    public let sessionId: String
    public let taskId: String
    public let seq: UInt64
    public let status: TaskStatus?
    public let title: String?
    public let message: String?
    public let appBundleId: String?
    public let deepLinkURL: String?
    public let cwd: String?
    public let pid: Int32?
    public let isPriming: Bool
    public let provenLive: Bool
    public let timestamp: Date

    public var key: TaskKey {
        TaskKey(source: source, sessionId: sessionId, taskId: taskId)
    }

    public init(
        type: TaskEventType,
        source: AgentSource,
        epoch: String,
        sessionId: String,
        taskId: String = "main",
        seq: UInt64,
        status: TaskStatus? = nil,
        title: String? = nil,
        message: String? = nil,
        appBundleId: String? = nil,
        deepLinkURL: String? = nil,
        cwd: String? = nil,
        pid: Int32? = nil,
        isPriming: Bool = false,
        provenLive: Bool = true,
        timestamp: Date = Date()
    ) {
        self.type = type
        self.source = source
        self.epoch = epoch
        self.sessionId = sessionId
        self.taskId = taskId
        self.seq = seq
        self.status = status
        self.title = title
        self.message = message
        self.appBundleId = appBundleId
        self.deepLinkURL = deepLinkURL
        self.cwd = cwd
        self.pid = pid
        self.isPriming = isPriming
        self.provenLive = provenLive
        self.timestamp = timestamp
    }
}

public struct AgentTask: Identifiable, Equatable, Sendable {
    public var id: TaskKey { key }
    public let key: TaskKey
    public var epoch: String
    public var lastSeq: UInt64
    public var title: String
    public var status: TaskStatus
    public var provenLive: Bool
    public var startedAt: Date
    public var updatedAt: Date
    public var lastHeartbeatAt: Date
    public var appBundleId: String?
    public var deepLinkURL: String?
    public var cwd: String?
    public var pid: Int32?
    public var pidStartTimeMicros: UInt64?
    public var message: String?

    public init(
        key: TaskKey,
        epoch: String,
        lastSeq: UInt64,
        title: String,
        status: TaskStatus,
        provenLive: Bool = true,
        startedAt: Date,
        updatedAt: Date,
        lastHeartbeatAt: Date,
        appBundleId: String? = nil,
        deepLinkURL: String? = nil,
        cwd: String? = nil,
        pid: Int32? = nil,
        pidStartTimeMicros: UInt64? = nil,
        message: String? = nil
    ) {
        self.key = key
        self.epoch = epoch
        self.lastSeq = lastSeq
        self.title = title
        self.status = status
        self.provenLive = provenLive
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.appBundleId = appBundleId
        self.deepLinkURL = deepLinkURL
        self.cwd = cwd
        self.pid = pid
        self.pidStartTimeMicros = pidStartTimeMicros
        self.message = message
    }
}

public struct TaskStoreSnapshot: Equatable, Sendable {
    public let version: UInt64
    public let tasks: [AgentTask]
    public let runningCount: Int
    public let confirmedRunningCount: Int
    public let waitingUserCount: Int

    public init(tasks: [AgentTask], version: UInt64 = 0) {
        self.version = version
        self.tasks = tasks.sorted { lhs, rhs in
            if lhs.status.sortPriority != rhs.status.sortPriority {
                return lhs.status.sortPriority < rhs.status.sortPriority
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        self.runningCount = tasks.filter { $0.status == .running }.count
        self.confirmedRunningCount = tasks.filter { $0.status == .running && $0.provenLive }.count
        self.waitingUserCount = tasks.filter { $0.status == .waitingUser }.count
    }
}
