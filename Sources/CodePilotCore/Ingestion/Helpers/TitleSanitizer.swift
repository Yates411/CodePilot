import Foundation

public enum TitleSanitizer {
    /// Cleans XML wrapper tags (e.g. `<USER_REQUEST>`), leading markdown noise,
    /// and collapses whitespace into a concise single-line task title.
    public static func clean(_ raw: String?, maxLength: Int = 42) -> String? {
        guard var text = raw else { return nil }

        // Drop trailing metadata blocks injected by Antigravity / host prompts
        let cutoffMarkers = [
            "<ADDITIONAL_METADATA>",
            "<USER_SETTINGS_CHANGE>",
            "The current local time is:"
        ]
        for marker in cutoffMarkers {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }

        // Strip common wrapper tags such as <USER_REQUEST>...</USER_REQUEST>
        let tagsToStrip = [
            "<USER_REQUEST>", "</USER_REQUEST>",
            "<ADDITIONAL_METADATA>", "</ADDITIONAL_METADATA>",
            "<SYSTEM_MESSAGE>", "</SYSTEM_MESSAGE>"
        ]
        for tag in tagsToStrip {
            text = text.replacingOccurrences(of: tag, with: " ")
        }

        // Strip any remaining simple <TAG>...</TAG> opening/closing markers at boundaries
        if let regex = try? NSRegularExpression(pattern: "</?[A-Z_]{3,32}>", options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        }

        // Remove leading markdown heading symbols (#, ##, -)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") || text.hasPrefix("-") || text.hasPrefix("*") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Collapse newlines and multiple spaces
        let components = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let collapsed = components.joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        guard maxLength > 0 else { return nil }
        if collapsed.count > maxLength {
            if maxLength == 1 {
                return String(collapsed.prefix(1))
            }
            return String(collapsed.prefix(maxLength - 1)) + "…"
        }
        return collapsed
    }

    /// Detects internal non-interactive bridge/review prompts so they don't clutter user task lists.
    public static func isInternalBridgePrompt(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let markers = [
            "Applications mentioned by the user:",
            "不要调用任何工具，请作为资深 macOS",
            "请作为资深 macOS/Swift 6 架构师",
            "请作为资深 macOS/AppKit/SwiftUI 架构师",
            "请只读复审以下",
            "请只读审阅以下"
        ]
        return markers.contains { text.contains($0) }
    }
}
