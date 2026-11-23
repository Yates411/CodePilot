import AppKit
import ApplicationServices
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

/// Pure scoring helper for matching a macOS window title / document path against a task.
public enum WindowMatchScorer {
    public static func searchTokens(for task: AgentTask) -> [String] {
        var tokens: [String] = []
        let trimmedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.count >= 2 {
            tokens.append(trimmedTitle)
            // Also include a shorter prefix in case the window truncates long titles.
            if trimmedTitle.count > 16 {
                tokens.append(String(trimmedTitle.prefix(16)))
            }
        }
        if let cwd = task.cwd, !cwd.isEmpty {
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            if folder.count >= 2 && !tokens.contains(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }) {
                tokens.append(folder)
            }
        }
        let sid = task.key.sessionId
        if sid.count >= 6 {
            tokens.append(String(sid.prefix(8)))
        }
        return tokens
    }

    public static func score(windowTitle: String?, document: String?, for task: AgentTask) -> Int {
        let titleLower = (windowTitle ?? "").lowercased()
        let docLower = (document ?? "").lowercased()
        guard !titleLower.isEmpty || !docLower.isEmpty else { return 0 }

        var best = 0
        let taskTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if taskTitle.count >= 2 {
            if titleLower.contains(taskTitle) {
                best = max(best, 100)
            } else if taskTitle.count > 12, titleLower.contains(String(taskTitle.prefix(12))) {
                best = max(best, 80)
            }
        }

        if let cwd = task.cwd, !cwd.isEmpty {
            let cwdLower = cwd.lowercased()
            let folderLower = URL(fileURLWithPath: cwd).lastPathComponent.lowercased()
            if !docLower.isEmpty && docLower.contains(cwdLower) {
                best = max(best, 95)
            }
            if folderLower.count >= 2 {
                if titleLower.contains(folderLower) {
                    best = max(best, 75)
                } else if !docLower.isEmpty && docLower.contains(folderLower) {
                    best = max(best, 70)
                }
            }
        }

        let sid = task.key.sessionId.lowercased()
        if sid.count >= 6 {
            let prefix = String(sid.prefix(8))
            if titleLower.contains(sid) {
                best = max(best, 90)
            } else if titleLower.contains(prefix) {
                best = max(best, 55)
            }
        }

        return best
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

        // 2. Locate best running application candidate.
        if let targetApp = resolveRunningApp(for: task, in: runningApps) {
            return focusRunningApp(targetApp, for: task)
        }

        // 3. Fallback: launch installed app from /Applications or ~/Applications.
        let candidateNames = Self.candidateAppNames(for: task.key.source)
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

    private func resolveRunningApp(for task: AgentTask, in runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        // 2a. Exact bundle identifier match.
        if let bundleId = task.appBundleId, !bundleId.isEmpty,
           let app = runningApps.first(where: { $0.bundleIdentifier == bundleId }) {
            return app
        }

        // 2b. Exact localized application name match.
        let candidateNames = Self.candidateAppNames(for: task.key.source)
        for name in candidateNames {
            if let app = runningApps.first(where: {
                $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return app
            }
        }

        // 2c. Antigravity fuzzy fallback.
        if task.key.source == .antigravity {
            if let app = runningApps.first(where: {
                ($0.bundleIdentifier?.lowercased().contains("antigravity") ?? false)
                    || ($0.localizedName?.lowercased().contains("antigravity") ?? false)
            }) {
                return app
            }
        }

        return nil
    }

    private func focusRunningApp(_ app: NSRunningApplication, for task: AgentTask) -> Bool {
        if app.isHidden {
            app.unhide()
        }

        // If the resolved host is a terminal (iTerm2 / Terminal.app), try switching directly to the matching tab first.
        if let bundleId = app.bundleIdentifier {
            if bundleId == "com.googlecode.iterm2",
               selectTerminalTab(appName: "iTerm2", for: task) {
                return app.activate(options: [])
            }
            if bundleId == "com.apple.Terminal",
               selectTerminalTab(appName: "Terminal", for: task) {
                return app.activate(options: [])
            }
        }

        // If Accessibility permission is granted, raise the specific window matching the task title / cwd / sessionId.
        if AXIsProcessTrusted(), focusBestMatchingWindow(pid: app.processIdentifier, for: task) {
            return app.activate(options: [])
        }

        return app.activate(options: [.activateAllWindows])
    }

    /// Uses macOS Accessibility API (when authorized) to locate and raise the window
    /// whose title or document path best matches the clicked task.
    private func focusBestMatchingWindow(pid: pid_t, for task: AgentTask) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return false
        }

        var bestWindow: AXUIElement?
        var bestScore = 0

        for win in windows {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String

            var docRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docRef)
            let doc = docRef as? String

            let score = WindowMatchScorer.score(windowTitle: title, document: doc, for: task)
            if score > bestScore {
                bestScore = score
                bestWindow = win
            }
        }

        guard let target = bestWindow, bestScore > 0 else {
            return false
        }

        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raiseResult = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        return raiseResult == .success
    }

    /// Attempts to switch to a specific tab/window in iTerm2 or Terminal.app matching the task's cwd or title.
    private func selectTerminalTab(appName: String, for task: AgentTask) -> Bool {
        let tokens = WindowMatchScorer.searchTokens(for: task)
        guard !tokens.isEmpty else { return false }

        for rawToken in tokens {
            let escaped = rawToken
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source: String
            if appName == "iTerm2" {
                source = """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if (name of s as text) contains "\(escaped)" then
                                    select t
                                    select w
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return false
                """
            } else {
                source = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if (custom title of t as text) contains "\(escaped)" or (name of w as text) contains "\(escaped)" then
                                set selected of t to true
                                set index of w to 1
                                return true
                            end if
                        end repeat
                    end repeat
                end tell
                return false
                """
            }

            if let script = NSAppleScript(source: source) {
                var errDict: NSDictionary?
                let result = script.executeAndReturnError(&errDict)
                if errDict == nil && result.booleanValue {
                    return true
                }
            }
        }
        return false
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
