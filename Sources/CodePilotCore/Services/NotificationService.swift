import AppKit
import Foundation
import UserNotifications

@MainActor
public final class NotificationService {
    public private(set) var authorizationStatusText: String = "未检测"
    public private(set) var isAuthorized: Bool = false
    private let hasAppBundle: Bool
    private var activeSound: NSSound?

    public init() {
        self.hasAppBundle = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public func refreshAuthorizationStatus(onUpdate: (@MainActor (String, Bool) -> Void)? = nil) {
        guard hasAppBundle else {
            authorizationStatusText = "仅打包 .app 可用"
            isAuthorized = false
            onUpdate?(authorizationStatusText, false)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let text: String
            let allowed: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                text = "已允许"
                allowed = true
            case .denied:
                text = "未允许"
                allowed = false
            case .notDetermined:
                text = "未授权"
                allowed = false
            @unknown default:
                text = "未知"
                allowed = false
            }
            Task { @MainActor in
                self?.authorizationStatusText = text
                self?.isAuthorized = allowed
                onUpdate?(text, allowed)
            }
        }
    }

    public func requestAuthorizationIfAvailable(onUpdate: (@MainActor (String, Bool) -> Void)? = nil) {
        guard hasAppBundle else {
            refreshAuthorizationStatus(onUpdate: onUpdate)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshAuthorizationStatus(onUpdate: onUpdate)
            }
        }
    }

    public func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public func previewSound(named name: String, volume: Double) {
        let clampedVolume = Float(max(0.0, min(1.0, volume)))
        let sound: NSSound?
        if let customURL = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            sound = NSSound(contentsOf: customURL, byReference: true)
        } else {
            sound = NSSound(named: NSSound.Name(name))
        }
        guard let sound else { return }
        activeSound?.stop()
        sound.volume = clampedVolume
        activeSound = sound
        sound.play()
    }

    @discardableResult
    public func notifyTask(_ task: AgentTask, isRepeat: Bool = false, settings: AppSettings) -> String {
        var feedbackParts: [String] = []

        if settings.soundEnabled {
            let soundName = soundName(for: task.status, settings: settings)
            if let soundName {
                previewSound(named: soundName, volume: settings.soundVolume)
                feedbackParts.append("响了「\(soundName)」")
            }
        } else {
            feedbackParts.append("提示音已关")
        }

        let allowStatusNotify: Bool
        switch task.status {
        case .waitingUser: allowStatusNotify = settings.notifyOnWaiting
        case .completed, .error: allowStatusNotify = settings.notifyOnCompleted
        case .running: allowStatusNotify = false
        }

        guard settings.notificationsEnabled, allowStatusNotify else {
            feedbackParts.append("未发通知：该状态通知已关")
            return feedbackParts.joined(separator: " · ")
        }

        guard hasAppBundle else {
            feedbackParts.append("未发通知：非 .app 环境")
            return feedbackParts.joined(separator: " · ")
        }

        if isAuthorized {
            postBanner(for: task, isRepeat: isRepeat, showTitle: settings.showTitleInNotification)
            feedbackParts.append("已发系统通知")
        } else {
            feedbackParts.append("未发通知：系统通知\(authorizationStatusText)")
            // Refresh asynchronously for next time.
            refreshAuthorizationStatus()
        }

        return feedbackParts.joined(separator: " · ")
    }

    public func notifyLowBatteryCutoff(percentage: Int, notificationsEnabled: Bool) {
        guard notificationsEnabled, hasAppBundle, isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "CodePilot · 低电量保护"
        content.body = "电池电量已降至 \(percentage)%，已自动暂停 AI 防休眠以保护电池。"
        let request = UNNotificationRequest(
            identifier: "codepilot-low-battery",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func notifyLowQuota(identifier: String, title: String, body: String, notificationsEnabled: Bool) {
        guard notificationsEnabled, hasAppBundle, isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postBanner(for task: AgentTask, isRepeat: Bool, showTitle: Bool) {
        let content = UNMutableNotificationContent()
        switch task.status {
        case .waitingUser:
            content.title = isRepeat
                ? "\(task.key.source.displayName) · 仍在等你确认"
                : "\(task.key.source.displayName) · 等你确认"
        case .completed:
            content.title = "\(task.key.source.displayName) · 任务完成"
        case .error:
            content.title = "\(task.key.source.displayName) · 执行异常"
        case .running:
            return
        }

        if showTitle {
            content.subtitle = task.title
            if let msg = task.message, !msg.isEmpty {
                content.body = msg
            }
        } else {
            content.body = task.status == .waitingUser
                ? "有 1 个任务正在等你确认（隐私模式已隐藏标题）"
                : "有 1 个任务已完成（隐私模式已隐藏标题）"
        }

        let request = UNNotificationRequest(
            identifier: "codepilot-\(task.key.source.rawValue)-\(task.key.sessionId)-\(task.key.taskId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func soundName(for status: TaskStatus, settings: AppSettings) -> String? {
        switch status {
        case .waitingUser: return settings.waitingSoundName
        case .completed: return settings.completedSoundName
        case .error: return settings.errorSoundName
        case .running: return nil
        }
    }
}
