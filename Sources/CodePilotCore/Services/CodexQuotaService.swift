import Foundation

public struct CodexQuotaSnapshot: Equatable, Sendable {
    public let primaryRemainingPercent: Int?
    public let secondaryRemainingPercent: Int?
    public let primaryWindowMinutes: Int?
    public let secondaryWindowMinutes: Int?
    public let updatedAt: Date

    public init(
        primaryRemainingPercent: Int?,
        secondaryRemainingPercent: Int?,
        primaryWindowMinutes: Int? = nil,
        secondaryWindowMinutes: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.primaryRemainingPercent = primaryRemainingPercent
        self.secondaryRemainingPercent = secondaryRemainingPercent
        self.primaryWindowMinutes = primaryWindowMinutes
        self.secondaryWindowMinutes = secondaryWindowMinutes
        self.updatedAt = updatedAt
    }
}

/// Purely local, zero-network Codex quota reader.
/// Scans the tail 512 KB of recent `~/.codex/sessions/**/rollout-*.jsonl` files for `rate_limits`.
public struct CodexQuotaService: Sendable {
    public let sessionsDirectory: String

    public static var defaultSessionsDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/sessions"
    }

    public init(sessionsDirectory: String = CodexQuotaService.defaultSessionsDirectory) {
        self.sessionsDirectory = sessionsDirectory
    }

    public func readLatestQuota() -> CodexQuotaSnapshot? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: sessionsDirectory) else { return nil }

        var candidates: [(path: String, modDate: Date)] = []
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl"), URL(fileURLWithPath: rel).lastPathComponent.hasPrefix("rollout-") else {
                continue
            }
            let full = "\(sessionsDirectory)/\(rel)"
            if let modDate = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date {
                candidates.append((full, modDate))
            }
        }

        candidates.sort { $0.modDate > $1.modDate }

        for item in candidates.prefix(8) {
            if let snap = Self.parseRolloutTail(at: item.path, modDate: item.modDate) {
                return snap
            }
        }
        return nil
    }

    public static func parseRolloutTail(at path: String, modDate: Date = Date()) -> CodexQuotaSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let tailLimit: UInt64 = 512 * 1024
        let endOffset = (try? handle.seekToEnd()) ?? 0
        let startOffset = endOffset > tailLimit ? (endOffset - tailLimit) : 0
        try? handle.seek(toOffset: startOffset)

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("rate_limits"),
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let payload = obj["payload"] as? [String: Any]
            guard let rl = (payload?["rate_limits"] as? [String: Any]) ?? (obj["rate_limits"] as? [String: Any]) else {
                continue
            }

            let primary = rl["primary"] as? [String: Any]
            let secondary = rl["secondary"] as? [String: Any]
            let primaryRem = extractRemainingPercent(from: primary)
            let secondaryRem = extractRemainingPercent(from: secondary)

            if primaryRem != nil || secondaryRem != nil {
                return CodexQuotaSnapshot(
                    primaryRemainingPercent: primaryRem,
                    secondaryRemainingPercent: secondaryRem,
                    primaryWindowMinutes: (primary?["window_minutes"] as? NSNumber)?.intValue,
                    secondaryWindowMinutes: (secondary?["window_minutes"] as? NSNumber)?.intValue,
                    updatedAt: modDate
                )
            }
        }
        return nil
    }

    private static func extractRemainingPercent(from dict: [String: Any]?) -> Int? {
        guard let dict else { return nil }
        if let used = (dict["used_percent"] as? NSNumber)?.doubleValue {
            return max(0, min(100, Int((100.0 - used).rounded())))
        }
        if let rem = (dict["remaining_percent"] as? NSNumber)?.doubleValue {
            return max(0, min(100, Int(rem.rounded())))
        }
        return nil
    }
}
