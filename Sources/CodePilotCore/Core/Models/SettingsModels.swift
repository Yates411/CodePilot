import Foundation

public enum FullScreenNotchBehavior: String, Codable, CaseIterable, Sendable {
    case hide
    case waitingOnly = "waiting_only"
    case always

    public var displayName: String {
        switch self {
        case .hide: return "收起"
        case .waitingOnly: return "只在等你时显示"
        case .always: return "照常显示"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var autoKeepAwakeEnabled: Bool
    public var autoPreventDisplaySleep: Bool
    public var gracePeriodSeconds: Int
    public var lowBatteryThreshold: Int
    public var lowBatteryCancelsManual: Bool

    public var notificationsEnabled: Bool
    public var notifyOnWaiting: Bool
    public var notifyOnCompleted: Bool
    public var showTitleInNotification: Bool

    public var soundEnabled: Bool
    public var waitingSoundName: String
    public var completedSoundName: String
    public var errorSoundName: String
    public var soundVolume: Double

    public var repeatReminderEnabled: Bool
    public var repeatReminderIntervalSeconds: Int
    public var maxRepeatReminders: Int

    public var notchEnabled: Bool
    public var notchAutoPopupOnComplete: Bool
    public var notchAutoPopupOnWaiting: Bool
    public var notchToastDurationSeconds: Int
    public var notchFullScreenBehavior: FullScreenNotchBehavior

    public var antigravityEnabled: Bool
    public var deepseekHarnessEnabled: Bool
    public var kimiCodeEnabled: Bool
    public var workbuddyEnabled: Bool
    public var codexEnabled: Bool
    public var claudeCodeEnabled: Bool

    public var showDeepSeekBalance: Bool
    public var showCodexQuota: Bool
    public var hasCompletedOnboarding: Bool

    public var processRulesEnabled: Bool
    public var watchedProcessNames: [String]

    public var lowBalanceAlertEnabled: Bool
    public var deepseekLowBalanceThreshold: Double
    public var codexLowQuotaThreshold: Int
    public var githubUpdateRepo: String

    public static let defaultWatchedProcesses: [String] = ["xcodebuild", "swiftc", "pytest", "cargo", "docker", "ffmpeg"]
    public static let customSounds: [String] = ["Radar", "Chime", "Thud", "Pulse"]
    public static let systemSounds: [String] = ["Ping", "Glass", "Pop", "Hero", "Purr", "Submarine", "Tink"]
    public static let availableSounds: [String] = customSounds + systemSounds

    public init(
        autoKeepAwakeEnabled: Bool = true,
        autoPreventDisplaySleep: Bool = false,
        gracePeriodSeconds: Int = 180,
        lowBatteryThreshold: Int = 20,
        lowBatteryCancelsManual: Bool = false,
        notificationsEnabled: Bool = true,
        notifyOnWaiting: Bool = true,
        notifyOnCompleted: Bool = true,
        showTitleInNotification: Bool = true,
        soundEnabled: Bool = true,
        waitingSoundName: String = "Radar",
        completedSoundName: String = "Chime",
        errorSoundName: String = "Thud",
        soundVolume: Double = 0.7,
        repeatReminderEnabled: Bool = true,
        repeatReminderIntervalSeconds: Int = 300,
        maxRepeatReminders: Int = 3,
        notchEnabled: Bool = true,
        notchAutoPopupOnComplete: Bool = true,
        notchAutoPopupOnWaiting: Bool = true,
        notchToastDurationSeconds: Int = 6,
        notchFullScreenBehavior: FullScreenNotchBehavior = .hide,
        antigravityEnabled: Bool = true,
        deepseekHarnessEnabled: Bool = true,
        kimiCodeEnabled: Bool = true,
        workbuddyEnabled: Bool = true,
        codexEnabled: Bool = true,
        claudeCodeEnabled: Bool = true,
        showDeepSeekBalance: Bool = true,
        showCodexQuota: Bool = true,
        hasCompletedOnboarding: Bool = false,
        processRulesEnabled: Bool = true,
        watchedProcessNames: [String] = AppSettings.defaultWatchedProcesses,
        lowBalanceAlertEnabled: Bool = true,
        deepseekLowBalanceThreshold: Double = 10.0,
        codexLowQuotaThreshold: Int = 15,
        githubUpdateRepo: String = "Yates411/CodePilot"
    ) {
        self.autoKeepAwakeEnabled = autoKeepAwakeEnabled
        self.autoPreventDisplaySleep = autoPreventDisplaySleep
        self.gracePeriodSeconds = max(0, min(3600, gracePeriodSeconds))
        self.lowBatteryThreshold = max(0, min(100, lowBatteryThreshold))
        self.lowBatteryCancelsManual = lowBatteryCancelsManual
        self.notificationsEnabled = notificationsEnabled
        self.notifyOnWaiting = notifyOnWaiting
        self.notifyOnCompleted = notifyOnCompleted
        self.showTitleInNotification = showTitleInNotification
        self.soundEnabled = soundEnabled
        self.waitingSoundName = waitingSoundName
        self.completedSoundName = completedSoundName
        self.errorSoundName = errorSoundName
        self.soundVolume = max(0.0, min(1.0, soundVolume))
        self.repeatReminderEnabled = repeatReminderEnabled
        self.repeatReminderIntervalSeconds = max(30, min(3600, repeatReminderIntervalSeconds))
        self.maxRepeatReminders = max(0, min(10, maxRepeatReminders))
        self.notchEnabled = notchEnabled
        self.notchAutoPopupOnComplete = notchAutoPopupOnComplete
        self.notchAutoPopupOnWaiting = notchAutoPopupOnWaiting
        self.notchToastDurationSeconds = [3, 6, 10].contains(notchToastDurationSeconds) ? notchToastDurationSeconds : 6
        self.notchFullScreenBehavior = notchFullScreenBehavior
        self.antigravityEnabled = antigravityEnabled
        self.deepseekHarnessEnabled = deepseekHarnessEnabled
        self.kimiCodeEnabled = kimiCodeEnabled
        self.workbuddyEnabled = workbuddyEnabled
        self.codexEnabled = codexEnabled
        self.claudeCodeEnabled = claudeCodeEnabled
        self.showDeepSeekBalance = showDeepSeekBalance
        self.showCodexQuota = showCodexQuota
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.processRulesEnabled = processRulesEnabled
        self.watchedProcessNames = watchedProcessNames
        self.lowBalanceAlertEnabled = lowBalanceAlertEnabled
        self.deepseekLowBalanceThreshold = max(0.0, min(10000.0, deepseekLowBalanceThreshold))
        self.codexLowQuotaThreshold = max(1, min(90, codexLowQuotaThreshold))
        self.githubUpdateRepo = githubUpdateRepo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.init(
            autoKeepAwakeEnabled: try c.decodeIfPresent(Bool.self, forKey: .autoKeepAwakeEnabled) ?? d.autoKeepAwakeEnabled,
            autoPreventDisplaySleep: try c.decodeIfPresent(Bool.self, forKey: .autoPreventDisplaySleep) ?? d.autoPreventDisplaySleep,
            gracePeriodSeconds: try c.decodeIfPresent(Int.self, forKey: .gracePeriodSeconds) ?? d.gracePeriodSeconds,
            lowBatteryThreshold: try c.decodeIfPresent(Int.self, forKey: .lowBatteryThreshold) ?? d.lowBatteryThreshold,
            lowBatteryCancelsManual: try c.decodeIfPresent(Bool.self, forKey: .lowBatteryCancelsManual) ?? d.lowBatteryCancelsManual,
            notificationsEnabled: try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled,
            notifyOnWaiting: try c.decodeIfPresent(Bool.self, forKey: .notifyOnWaiting) ?? d.notifyOnWaiting,
            notifyOnCompleted: try c.decodeIfPresent(Bool.self, forKey: .notifyOnCompleted) ?? d.notifyOnCompleted,
            showTitleInNotification: try c.decodeIfPresent(Bool.self, forKey: .showTitleInNotification) ?? d.showTitleInNotification,
            soundEnabled: try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? d.soundEnabled,
            waitingSoundName: try c.decodeIfPresent(String.self, forKey: .waitingSoundName) ?? d.waitingSoundName,
            completedSoundName: try c.decodeIfPresent(String.self, forKey: .completedSoundName) ?? d.completedSoundName,
            errorSoundName: try c.decodeIfPresent(String.self, forKey: .errorSoundName) ?? d.errorSoundName,
            soundVolume: try c.decodeIfPresent(Double.self, forKey: .soundVolume) ?? d.soundVolume,
            repeatReminderEnabled: try c.decodeIfPresent(Bool.self, forKey: .repeatReminderEnabled) ?? d.repeatReminderEnabled,
            repeatReminderIntervalSeconds: try c.decodeIfPresent(Int.self, forKey: .repeatReminderIntervalSeconds) ?? d.repeatReminderIntervalSeconds,
            maxRepeatReminders: try c.decodeIfPresent(Int.self, forKey: .maxRepeatReminders) ?? d.maxRepeatReminders,
            notchEnabled: try c.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? d.notchEnabled,
            notchAutoPopupOnComplete: try c.decodeIfPresent(Bool.self, forKey: .notchAutoPopupOnComplete) ?? d.notchAutoPopupOnComplete,
            notchAutoPopupOnWaiting: try c.decodeIfPresent(Bool.self, forKey: .notchAutoPopupOnWaiting) ?? d.notchAutoPopupOnWaiting,
            notchToastDurationSeconds: try c.decodeIfPresent(Int.self, forKey: .notchToastDurationSeconds) ?? d.notchToastDurationSeconds,
            notchFullScreenBehavior: try c.decodeIfPresent(FullScreenNotchBehavior.self, forKey: .notchFullScreenBehavior) ?? d.notchFullScreenBehavior,
            antigravityEnabled: try c.decodeIfPresent(Bool.self, forKey: .antigravityEnabled) ?? d.antigravityEnabled,
            deepseekHarnessEnabled: try c.decodeIfPresent(Bool.self, forKey: .deepseekHarnessEnabled) ?? d.deepseekHarnessEnabled,
            kimiCodeEnabled: try c.decodeIfPresent(Bool.self, forKey: .kimiCodeEnabled) ?? d.kimiCodeEnabled,
            workbuddyEnabled: try c.decodeIfPresent(Bool.self, forKey: .workbuddyEnabled) ?? d.workbuddyEnabled,
            codexEnabled: try c.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? d.codexEnabled,
            claudeCodeEnabled: try c.decodeIfPresent(Bool.self, forKey: .claudeCodeEnabled) ?? d.claudeCodeEnabled,
            showDeepSeekBalance: try c.decodeIfPresent(Bool.self, forKey: .showDeepSeekBalance) ?? d.showDeepSeekBalance,
            showCodexQuota: try c.decodeIfPresent(Bool.self, forKey: .showCodexQuota) ?? d.showCodexQuota,
            hasCompletedOnboarding: try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding,
            processRulesEnabled: try c.decodeIfPresent(Bool.self, forKey: .processRulesEnabled) ?? d.processRulesEnabled,
            watchedProcessNames: try c.decodeIfPresent([String].self, forKey: .watchedProcessNames) ?? d.watchedProcessNames,
            lowBalanceAlertEnabled: try c.decodeIfPresent(Bool.self, forKey: .lowBalanceAlertEnabled) ?? d.lowBalanceAlertEnabled,
            deepseekLowBalanceThreshold: try c.decodeIfPresent(Double.self, forKey: .deepseekLowBalanceThreshold) ?? d.deepseekLowBalanceThreshold,
            codexLowQuotaThreshold: try c.decodeIfPresent(Int.self, forKey: .codexLowQuotaThreshold) ?? d.codexLowQuotaThreshold,
            githubUpdateRepo: try c.decodeIfPresent(String.self, forKey: .githubUpdateRepo) ?? d.githubUpdateRepo
        )
    }

    public func toPowerPolicy() -> PowerPolicy {
        PowerPolicy(
            autoKeepAwakeEnabled: autoKeepAwakeEnabled,
            autoLevel: autoPreventDisplaySleep ? .systemAndDisplay : .systemOnly,
            gracePeriod: .seconds(gracePeriodSeconds),
            lowBatteryThreshold: lowBatteryThreshold,
            lowBatteryHysteresis: 5,
            lowBatteryCancelsManual: lowBatteryCancelsManual
        )
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.codepilot.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
