import Darwin
import Foundation

public enum UnixSocketServerError: Error, Equatable, Sendable {
    case pathTooLong(maxBytes: Int)
    case unsafeExistingPath(String)
    case createDirectoryFailed(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias EventHandler = @Sendable (TaskEvent) async -> Void

    public static var defaultSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codepilot/events.sock"
    }

    public let socketPath: String
    private let maxConcurrentConnections: Int
    private let ioTimeoutSeconds: Int
    private let lifecycleLock = NSLock()
    private let connLock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning = false
    private var activeConnections = 0
    private let acceptQueue = DispatchQueue(label: "com.codepilot.unixsocket.accept", qos: .utility)
    private let clientQueue = DispatchQueue(label: "com.codepilot.unixsocket.clients", qos: .utility, attributes: .concurrent)

    public init(
        socketPath: String = UnixSocketServer.defaultSocketPath,
        maxConcurrentConnections: Int = 64,
        ioTimeoutSeconds: Int = 5
    ) {
        self.socketPath = socketPath
        self.maxConcurrentConnections = max(1, maxConcurrentConnections)
        self.ioTimeoutSeconds = max(1, ioTimeoutSeconds)
    }

    deinit {
        stop()
    }

    public func start(onEvent: @escaping EventHandler) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if isRunning {
            return
        }

        var addr = sockaddr_un()
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= maxPathBytes else {
            throw UnixSocketServerError.pathTooLong(maxBytes: maxPathBytes)
        }

        // Isolate access via 0700 parent directory rather than mutating process-global umask.
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = Darwin.chmod(parentDir, 0o700)
        } catch {
            throw UnixSocketServerError.createDirectoryFailed(error.localizedDescription)
        }

        // Safely remove stale socket file ONLY if lstat confirms it is a socket owned by current UID.
        var st = stat()
        if lstat(socketPath, &st) == 0 {
            let isSocket = (st.st_mode & S_IFMT) == S_IFSOCK
            let ownedBySelf = (st.st_uid == getuid())
            guard isSocket && ownedBySelf else {
                throw UnixSocketServerError.unsafeExistingPath(socketPath)
            }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketServerError.socketFailed(errno)
        }

        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: maxPathBytes + 1) { dst in
                for i in 0..<utf8.count {
                    dst[i] = utf8[i]
                }
                dst[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw UnixSocketServerError.bindFailed(err)
        }

        _ = Darwin.chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 32) == 0 else {
            let err = errno
            close(fd)
            unlink(socketPath)
            throw UnixSocketServerError.listenFailed(err)
        }

        listenFD = fd
        isRunning = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop(listenFD: fd, onEvent: onEvent)
        }
    }

    public func stop() {
        lifecycleLock.lock()
        let fd = listenFD
        listenFD = -1
        let wasRunning = isRunning
        isRunning = false
        lifecycleLock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        if wasRunning {
            var st = stat()
            if lstat(socketPath, &st) == 0,
               (st.st_mode & S_IFMT) == S_IFSOCK,
               st.st_uid == getuid() {
                unlink(socketPath)
            }
        }
    }

    private func acceptLoop(listenFD: Int32, onEvent: @escaping EventHandler) {
        while true {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFD, saPtr, &addrLen)
                }
            }

            if clientFD < 0 {
                let err = errno
                if err == EINTR { continue }
                break
            }

            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var euid: uid_t = 0
            var egid: gid_t = 0
            if getpeereid(clientFD, &euid, &egid) != 0 || euid != getuid() {
                close(clientFD)
                continue
            }

            connLock.lock()
            let canAccept = activeConnections < maxConcurrentConnections
            if canAccept {
                activeConnections += 1
            }
            connLock.unlock()

            guard canAccept else {
                close(clientFD)
                continue
            }

            var tv = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            clientQueue.async { [weak self] in
                defer {
                    close(clientFD)
                    self?.decrementConnections()
                }
                self?.handleClient(fd: clientFD, onEvent: onEvent)
            }
        }
    }

    private func decrementConnections() {
        connLock.lock()
        activeConnections = max(0, activeConnections - 1)
        connLock.unlock()
    }

    private func handleClient(fd: Int32, onEvent: @escaping EventHandler) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = Data(buffer[..<newlineIndex])
                    buffer.removeSubrange(...newlineIndex)

                    if lineData.isEmpty { continue }
                    let ack = processLine(lineData, onEvent: onEvent)
                    if !writeAll(fd: fd, data: ack.encodedLine()) {
                        return
                    }
                }

                if buffer.count > EventEnvelope.maxLineBytes {
                    _ = writeAll(fd: fd, data: EventAck(ok: false, error: "line_too_long").encodedLine())
                    return
                }
            } else if n == 0 {
                // NDJSON requires explicit '\n' frame delimiter; reject truncated trailing data.
                if !buffer.isEmpty {
                    _ = writeAll(fd: fd, data: EventAck(ok: false, error: "incomplete_frame").encodedLine())
                }
                return
            } else {
                if errno == EINTR { continue }
                return
            }
        }
    }

    private func processLine(_ lineData: Data, onEvent: @escaping EventHandler) -> EventAck {
        do {
            let envelope = try EventEnvelope.decode(lineData: lineData)
            let event = envelope.toTaskEvent()
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task {
                await onEvent(event)
                semaphore.signal()
            }
            let waitResult = semaphore.wait(timeout: .now() + .seconds(ioTimeoutSeconds))
            if waitResult == .timedOut {
                task.cancel()
                return EventAck(ok: false, seq: envelope.seq, error: "handler_timeout")
            }
            return EventAck(ok: true, seq: envelope.seq)
        } catch let err as EventEnvelopeError {
            return EventAck(ok: false, error: "\(err)")
        } catch {
            return EventAck(ok: false, error: error.localizedDescription)
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var totalWritten = 0
            while totalWritten < data.count {
                let written = Darwin.write(fd, base.advanced(by: totalWritten), data.count - totalWritten)
                if written > 0 {
                    totalWritten += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
