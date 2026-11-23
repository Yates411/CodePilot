import CryptoKit
import Foundation

public struct GitHubReleaseInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let zipAssetURL: URL?
    public let zipAssetName: String?
    public let checksumsURL: URL?
    public let releaseNotes: String

    public init(
        version: String,
        tagName: String,
        releaseURL: URL,
        zipAssetURL: URL?,
        zipAssetName: String?,
        checksumsURL: URL?,
        releaseNotes: String
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.zipAssetURL = zipAssetURL
        self.zipAssetName = zipAssetName
        self.checksumsURL = checksumsURL
        self.releaseNotes = releaseNotes
    }
}

public enum GitHubUpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(GitHubReleaseInfo)
}

public enum GitHubUpdateError: Error, LocalizedError, Sendable {
    case invalidRepository
    case networkError(String)
    case invalidResponse
    case noZipAsset
    case checksumMismatch
    case extractionFailed(String)
    case notInstalledAsAppBundle

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "GitHub 仓库格式应为 owner/repo（例如 yourname/CodePilot）"
        case .networkError(let msg):
            return "网络请求失败：\(msg)"
        case .invalidResponse:
            return "无法解析 GitHub Release 响应（请确认仓库已公开且已发布 Release）"
        case .noZipAsset:
            return "该 Release 未包含 .zip 安装包，请前往 GitHub 页面手动下载"
        case .checksumMismatch:
            return "安装包 SHA-256 校验失败，已中止更新以保障安全"
        case .extractionFailed(let msg):
            return "解压更新包失败：\(msg)"
        case .notInstalledAsAppBundle:
            return "仅支持在打包后的 .app 环境中原地更新"
        }
    }
}

public final class GitHubUpdateService: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Compares two semantic version strings (ignoring leading "v"), returning true if `latest` > `current`.
    public static func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let lhs = parseSemver(latest)
        let rhs = parseSemver(current)
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b {
                return a > b
            }
        }
        return false
    }

    private static func parseSemver(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "v", with: "", options: .anchored)
        let core = trimmed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? trimmed
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    public static func parseReleaseJSON(_ data: Data) throws -> GitHubReleaseInfo {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = obj["tag_name"] as? String,
              let htmlURLString = obj["html_url"] as? String,
              let releaseURL = URL(string: htmlURLString) else {
            throw GitHubUpdateError.invalidResponse
        }

        let version = tagName.hasPrefix("v") || tagName.hasPrefix("V")
            ? String(tagName.dropFirst())
            : tagName
        let notes = (obj["body"] as? String) ?? ""

        var zipURL: URL?
        var zipName: String?
        var checksumsURL: URL?

        if let assets = obj["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      let dl = asset["browser_download_url"] as? String,
                      let url = URL(string: dl) else {
                    continue
                }
                let lower = name.lowercased()
                if lower.hasSuffix(".zip") && (zipURL == nil || lower.contains("arm64")) {
                    zipURL = url
                    zipName = name
                } else if lower == "sha256sums" || lower.hasSuffix("sha256sums.txt") {
                    checksumsURL = url
                }
            }
        }

        return GitHubReleaseInfo(
            version: version,
            tagName: tagName,
            releaseURL: releaseURL,
            zipAssetURL: zipURL,
            zipAssetName: zipName,
            checksumsURL: checksumsURL,
            releaseNotes: notes
        )
    }

    public func checkForUpdate(repository: String, currentVersion: String) async throws -> GitHubUpdateCheckResult {
        let cleaned = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: "/")
        guard parts.count == 2,
              !parts[0].isEmpty, !parts[1].isEmpty,
              let apiURL = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest") else {
            throw GitHubUpdateError.invalidRepository
        }

        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CodePilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GitHubUpdateError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GitHubUpdateError.invalidResponse
        }

        let info = try Self.parseReleaseJSON(data)
        if Self.isNewerVersion(info.version, than: currentVersion) {
            return .updateAvailable(info)
        }
        return .upToDate(currentVersion: currentVersion, latestVersion: info.version)
    }

    /// Downloads the release `.zip`, optionally verifies SHA-256 against `SHA256SUMS`,
    /// extracts `CodePilot.app`, and launches a detached updater script to atomically replace & relaunch.
    public func downloadAndInstall(release: GitHubReleaseInfo, currentAppURL: URL) async throws {
        guard currentAppURL.pathExtension == "app" else {
            throw GitHubUpdateError.notInstalledAsAppBundle
        }
        guard let zipURL = release.zipAssetURL else {
            throw GitHubUpdateError.noZipAsset
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("CodePilotUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let zipPath = workDir.appendingPathComponent(release.zipAssetName ?? "CodePilot-update.zip")
        var zipReq = URLRequest(url: zipURL)
        zipReq.timeoutInterval = 120
        let (tmpFile, resp) = try await session.download(for: zipReq)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GitHubUpdateError.networkError("下载安装包返回异常状态码")
        }
        try? fm.removeItem(at: zipPath)
        try fm.moveItem(at: tmpFile, to: zipPath)

        // Verify SHA-256 if SHA256SUMS asset is provided alongside the release
        if let sumsURL = release.checksumsURL, let assetName = release.zipAssetName {
            let (sumsData, sumsResp) = try await session.data(from: sumsURL)
            if let sumsHTTP = sumsResp as? HTTPURLResponse, (200...299).contains(sumsHTTP.statusCode),
               let sumsText = String(data: sumsData, encoding: .utf8),
               let expectedHash = Self.extractChecksum(for: assetName, from: sumsText) {
                let actualHash = try Self.sha256Hex(of: zipPath)
                guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                    try? fm.removeItem(at: workDir)
                    throw GitHubUpdateError.checksumMismatch
                }
            }
        }

        let extractDir = workDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipPath.path, extractDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw GitHubUpdateError.extractionFailed("ditto exit \(ditto.terminationStatus)")
        }

        guard let newAppURL = Self.findAppBundle(in: extractDir) else {
            throw GitHubUpdateError.extractionFailed("压缩包中未找到 CodePilot.app")
        }

        // Launch detached helper script that waits for current PID, swaps .app, and relaunches
        let scriptPath = workDir.appendingPathComponent("apply_update.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let targetPath = currentAppURL.path
        let sourcePath = newAppURL.path
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(targetPath)"
        /usr/bin/ditto "\(sourcePath)" "\(targetPath)"
        /usr/bin/touch "\(targetPath)"
        /usr/bin/open "\(targetPath)"
        rm -rf "\(workDir.path)"
        """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [scriptPath.path]
        try launcher.run()
    }

    public static func extractChecksum(for filename: String, from sumsText: String) -> String? {
        for rawLine in sumsText.components(separatedBy: .newlines) {
            let parts = rawLine.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0])
            let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == filename || name.hasSuffix("/\(filename)") {
                return hash
            }
        }
        return nil
    }

    private static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func findAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("CodePilot.app")
        if fm.fileExists(atPath: direct.path) {
            return direct
        }
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            return items.first { $0.pathExtension == "app" }
        }
        return nil
    }
}
