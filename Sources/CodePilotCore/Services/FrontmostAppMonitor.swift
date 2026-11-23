import AppKit
import Foundation

@MainActor
public final class FrontmostAppMonitor {
    public typealias Handler = @Sendable (AgentSource) -> Void

    private var observer: NSObjectProtocol?

    public init() {}

    isolated deinit {
        stop()
    }

    public func start(onActivateSource: @escaping Handler) {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            if let source = Self.mapApplicationToSource(bundleId: app.bundleIdentifier, name: app.localizedName) {
                onActivateSource(source)
            }
        }
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    public nonisolated static func mapApplicationToSource(bundleId: String?, name: String?) -> AgentSource? {
        let lowerId = bundleId?.lowercased() ?? ""
        let lowerName = name?.lowercased() ?? ""

        if lowerId.contains("antigravity") || lowerName == "antigravity" || lowerName == "antigravity ide" {
            return .antigravity
        }
        if lowerId.contains("deepseek") || lowerName == "deepseek harness" {
            return .deepseekHarness
        }
        if lowerId.contains("workbuddy") || lowerName == "workbuddy" {
            return .workbuddy
        }
        if lowerName == "kimi code" {
            return .kimiCode
        }
        if lowerId.contains("codex") || lowerName == "codex" {
            return .codex
        }
        if lowerId.contains("claude") || lowerName == "claude" {
            return .claudeCode
        }
        return nil
    }
}
