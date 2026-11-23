import Foundation

public enum EventEnvelopeError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidJSON(String)
    case lineTooLong
    case missingRequiredField(String)
    case invalidField(String)
}

public struct EventEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let type: TaskEventType
    public let source: AgentSource
    public let epoch: String
    public let sessionId: String
    public let taskId: String?
    public let seq: UInt64
    public let status: TaskStatus?
    public let title: String?
    public let message: String?
    public let appBundleId: String?
    public let cwd: String?
    public let pid: Int32?
    public let ts: Double?

    public init(
        v: Int = 1,
        type: TaskEventType,
        source: AgentSource,
        epoch: String,
        sessionId: String,
        taskId: String? = "main",
        seq: UInt64,
        status: TaskStatus? = nil,
        title: String? = nil,
        message: String? = nil,
        appBundleId: String? = nil,
        cwd: String? = nil,
        pid: Int32? = nil,
        ts: Double? = nil
    ) {
        self.v = v
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
        self.cwd = cwd
        self.pid = pid
        self.ts = ts
    }

    public static let maxLineBytes = 64 * 1024
    public static let maxIdentifierLength = 128

    public static func decode(lineData: Data) throws -> EventEnvelope {
        if lineData.count > maxLineBytes {
            throw EventEnvelopeError.lineTooLong
        }
        let envelope: EventEnvelope
        do {
            envelope = try JSONDecoder().decode(EventEnvelope.self, from: lineData)
        } catch {
            throw EventEnvelopeError.invalidJSON(error.localizedDescription)
        }

        guard envelope.v == 1 else {
            throw EventEnvelopeError.unsupportedVersion(envelope.v)
        }
        try validateIdentifier(envelope.epoch, name: "epoch")
        try validateIdentifier(envelope.sessionId, name: "sessionId")
        if let taskId = envelope.taskId, !taskId.isEmpty {
            try validateIdentifier(taskId, name: "taskId")
        }
        if envelope.type == .upsert && envelope.status == nil {
            throw EventEnvelopeError.missingRequiredField("status")
        }
        return envelope
    }

    private static func validateIdentifier(_ value: String, name: String) throws {
        if value.isEmpty {
            throw EventEnvelopeError.missingRequiredField(name)
        }
        if value.count > maxIdentifierLength {
            throw EventEnvelopeError.invalidField("\(name)_too_long")
        }
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw EventEnvelopeError.invalidField("\(name)_control_char")
            }
        }
    }

    public func toTaskEvent() -> TaskEvent {
        let timestamp = ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return TaskEvent(
            type: type,
            source: source,
            epoch: epoch,
            sessionId: sessionId,
            taskId: (taskId?.isEmpty == false ? taskId! : "main"),
            seq: seq,
            status: status,
            title: title,
            message: message,
            appBundleId: appBundleId,
            cwd: cwd,
            pid: pid,
            timestamp: timestamp
        )
    }
}

public struct EventAck: Codable, Equatable, Sendable {
    public let ok: Bool
    public let seq: UInt64?
    public let error: String?

    public init(ok: Bool, seq: UInt64? = nil, error: String? = nil) {
        self.ok = ok
        self.seq = seq
        self.error = error
    }

    public func encodedLine() -> Data {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{\"ok\":false}".utf8)
        var result = data
        result.append(0x0A) // '\n'
        return result
    }
}
