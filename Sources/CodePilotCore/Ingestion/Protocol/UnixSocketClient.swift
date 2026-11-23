import Darwin
import Foundation

public enum UnixSocketClientError: Error, LocalizedError, Sendable {
    case invalidSocketPath
    case socketCreateFailed(Int32)
    case connectFailed(Int32, String)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSocketPath:
            return "Invalid Unix socket path"
        case .socketCreateFailed(let code):
            return "Failed to create socket (errno=\(code))"
        case .connectFailed(let code, let path):
            return "Failed to connect to \(path) (errno=\(code)). Is CodePilot running?"
        case .writeFailed(let code):
            return "Failed to write event payload (errno=\(code))"
        }
    }
}

public enum UnixSocketClient {
    /// Sends a single NDJSON payload to CodePilot's local Unix domain socket and returns server reply.
    @discardableResult
    public static func send(payload: Data, socketPath: String = UnixSocketServer.defaultSocketPath) throws -> String {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard !pathBytes.isEmpty, pathBytes.count <= maxLen else {
            throw UnixSocketClientError.invalidSocketPath
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketClientError.socketCreateFailed(errno)
        }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            rawBuf.initializeMemory(as: UInt8.self, repeating: 0)
            for (idx, b) in pathBytes.enumerated() {
                rawBuf[idx] = b
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw UnixSocketClientError.connectFailed(errno, socketPath)
        }

        var lineData = payload
        if lineData.last != 0x0A {
            lineData.append(0x0A)
        }

        try lineData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            while written < lineData.count {
                let n = Darwin.write(fd, base.advanced(by: written), lineData.count - written)
                if n <= 0 {
                    throw UnixSocketClientError.writeFailed(errno)
                }
                written += n
            }
        }

        var replyBuf = [UInt8](repeating: 0, count: 512)
        let readCount = Darwin.read(fd, &replyBuf, replyBuf.count)
        if readCount > 0 {
            return String(decoding: replyBuf.prefix(readCount), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "{\"ok\":true}"
    }
}
