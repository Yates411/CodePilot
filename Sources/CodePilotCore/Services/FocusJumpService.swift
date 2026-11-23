import AppKit
import Foundation

public enum DeepLinkValidator {
    private static let allowedIdChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    /// Strictly validates allowed deep-link URLs to prevent arbitrary scheme injection.
    /// Allowed forms:
    /// - `codex://threads/<safe-id>`
    /// - `claude://code/continue?session=<safe-id>`
    public static func validatedURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, raw.count <= 256,
              let components = URLComponents(string: raw),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }

        switch scheme {
        case "codex":
            guard host == "threads",
                  components.queryItems == nil else {
                return nil
            }
            let path = components.path
            guard path.hasPrefix("/") else { return nil }
            let id = String(path.dropFirst())
            guard isSafeId(id) else { return nil }
            return components.url

        case "claude":
            guard host == "code",
                  components.path == "/continue",
                  let items = components.queryItems,
                  items.count == 1,
                  items[0].name == "session",
                  let sessionId = items[0].value,
                  isSafeId(sessionId) else {
                return nil
            }
            return components.url

        default:
            return nil
        }
    }

    private static func isSafeId(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128, !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy { allowedIdChars.contains($0) }
    }
}

@MainActor
public final class FocusJumpService {
    public init() {}

    @discardableResult
    public func focusApp(for task: AgentTask) async -> Bool {
        // 1. Prefer strictly validated session deep-link URL (e.g. codex://threads/<id>, claude://code/continue?session=<id>).
        if let deepURL = DeepLinkValidator.validatedURL(from: task.deepLinkURL) {
            if NSWorkspace.shared.urlForApplication(toOpen: deepURL) != nil {
                let opened = NSWorkspace.shared.open(deepURL)
                if opened { return true }
            }
        }

        let runningApps = NSWorkspace.shared.runningApplications

        // 2. Exact bundle identifier match.
        if let bundleId = task.appBundleId, !bundleId.isEmpty,
           let app = runningApps.first(where: { $0.bundleIdentifier == bundleId }) {
            return app.activate(options: [.activateAllWindows])
        }

        // 3. Exact localized application name match, then case-insensitive bundleId/name fallback.
        let candidateNames = Self.candidateAppNames(for: task.key.source)
        for name in candidateNames {
            if let app = runningApps.first(where: {
                $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return activate(app)
            }
        }

        if task.key.source == .antigravity {
            if let app = runningApps.first(where: {
                ($0.bundleIdentifier?.lowercased().contains("antigravity") ?? false)
                    || ($0.localizedName?.lowercased().contains("antigravity") ?? false)
            }) {
                return activate(app)
            }
        }

        // 4. Try opening installed app from /Applications or ~/Applications.
        let appDirs = [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        for dir in appDirs {
            for name in candidateNames {
                let appURL = URL(fileURLWithPath: "\(dir)/\(name).app")
                if FileManager.default.fileExists(atPath: appURL.path) {
                    do {
                        _ = try await NSWorkspace.shared.openApplication(
                            at: appURL,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                        return true
                    } catch {
                        continue
                    }
                }
            }
        }

        return false
    }

    private func activate(_ app: NSRunningApplication) -> Bool {
        if app.isHidden {
            app.unhide()
        }
        return app.activate(options: [.activateAllWindows])
    }

    private static func candidateAppNames(for source: AgentSource) -> [String] {
        switch source {
        case .antigravity:
            return ["Antigravity", "Antigravity IDE"]
        case .kimiCode:
            return ["Kimi Code", "iTerm2", "Ghostty", "Terminal"]
        case .workbuddy:
            return ["WorkBuddy"]
        case .codex:
            return ["Codex", "iTerm2", "Ghostty", "Terminal"]
        case .deepseekHarness:
            return ["DeepSeek Harness"]
        case .claudeCode:
            return ["Claude", "iTerm2", "Ghostty", "Terminal"]
        case .custom:
            return ["iTerm2", "Ghostty", "Terminal"]
        }
    }
}
