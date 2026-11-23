import Foundation

public enum PowerAssertionLevel: Int, Comparable, Codable, Sendable {
    case systemOnly = 1
    case systemAndDisplay = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .systemOnly: return "防系统休眠（允许息屏）"
        case .systemAndDisplay: return "防系统休眠与息屏"
        }
    }
}

public enum PowerLeaseKind: Hashable, Sendable {
    case manualIndefinite
    case manualTimed(id: UUID)
    case processRule(name: String)
    case aiAuto

    public var priority: Int {
        switch self {
        case .manualIndefinite: return 100
        case .manualTimed: return 80
        case .processRule: return 60
        case .aiAuto: return 40
        }
    }

    public var isManual: Bool {
        switch self {
        case .manualIndefinite, .manualTimed:
            return true
        case .processRule, .aiAuto:
            return false
        }
    }
}

public struct PowerLease: Equatable, Sendable {
    public let kind: PowerLeaseKind
    public let reason: String
    public let level: PowerAssertionLevel
    public let createdAt: ContinuousClock.Instant
    public let expiresAt: ContinuousClock.Instant?

    public init(
        kind: PowerLeaseKind,
        reason: String,
        level: PowerAssertionLevel,
        createdAt: ContinuousClock.Instant,
        expiresAt: ContinuousClock.Instant? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.level = level
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: ContinuousClock.Instant) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}

public struct BatteryStatus: Equatable, Sendable {
    public let isOnBattery: Bool
    public let percentage: Int

    public init(isOnBattery: Bool, percentage: Int) {
        self.isOnBattery = isOnBattery
        self.percentage = max(0, min(100, percentage))
    }
}

public struct PowerPolicy: Equatable, Sendable {
    public var autoKeepAwakeEnabled: Bool
    public var autoLevel: PowerAssertionLevel
    public var gracePeriod: Duration
    public var lowBatteryThreshold: Int
    public var lowBatteryHysteresis: Int
    public var lowBatteryCancelsManual: Bool

    public init(
        autoKeepAwakeEnabled: Bool = true,
        autoLevel: PowerAssertionLevel = .systemOnly,
        gracePeriod: Duration = .seconds(180),
        lowBatteryThreshold: Int = 20,
        lowBatteryHysteresis: Int = 5,
        lowBatteryCancelsManual: Bool = false
    ) {
        let clampedThreshold = max(0, min(100, lowBatteryThreshold))
        let clampedHysteresis = max(0, min(100 - clampedThreshold, lowBatteryHysteresis))
        self.autoKeepAwakeEnabled = autoKeepAwakeEnabled
        self.autoLevel = autoLevel
        self.gracePeriod = gracePeriod < .zero ? .zero : gracePeriod
        self.lowBatteryThreshold = clampedThreshold
        self.lowBatteryHysteresis = clampedHysteresis
        self.lowBatteryCancelsManual = lowBatteryCancelsManual
    }

    public func normalized() -> PowerPolicy {
        PowerPolicy(
            autoKeepAwakeEnabled: autoKeepAwakeEnabled,
            autoLevel: autoLevel,
            gracePeriod: gracePeriod,
            lowBatteryThreshold: lowBatteryThreshold,
            lowBatteryHysteresis: lowBatteryHysteresis,
            lowBatteryCancelsManual: lowBatteryCancelsManual
        )
    }
}

public struct PowerManagerSnapshot: Equatable, Sendable {
    public let version: UInt64
    public let activeLevel: PowerAssertionLevel?
    public let activeLeases: [PowerLease]
    public let isAutoBlockedByLowBattery: Bool
    public let graceDeadline: ContinuousClock.Instant?
    public let lastError: String?

    public init(
        version: UInt64 = 0,
        activeLevel: PowerAssertionLevel? = nil,
        activeLeases: [PowerLease] = [],
        isAutoBlockedByLowBattery: Bool = false,
        graceDeadline: ContinuousClock.Instant? = nil,
        lastError: String? = nil
    ) {
        self.version = version
        self.activeLevel = activeLevel
        self.activeLeases = activeLeases
        self.isAutoBlockedByLowBattery = isAutoBlockedByLowBattery
        self.graceDeadline = graceDeadline
        self.lastError = lastError
    }

    public var isKeepingAwake: Bool {
        activeLevel != nil
    }

    public var primaryReason: String? {
        activeLeases.max(by: { $0.kind.priority < $1.kind.priority })?.reason
    }
}
