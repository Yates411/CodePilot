import Darwin
import Foundation

public struct JSONLTailState: Equatable, Sendable {
    public var inode: UInt64
    public var byteOffset: UInt64
    public var partialBuffer: Data
    public var discardUntilNextNewline: Bool

    public init(
        inode: UInt64,
        byteOffset: UInt64,
        partialBuffer: Data = Data(),
        discardUntilNextNewline: Bool = false
    ) {
        self.inode = inode
        self.byteOffset = byteOffset
        self.partialBuffer = partialBuffer
        self.discardUntilNextNewline = discardUntilNextNewline
    }
}

/// On-demand, short-open JSONL incremental reader.
/// Serializes read/parse/commit per path and never keeps FDs open across polls.
public final class JSONLTailer: @unchecked Sendable {
    public let maxLineBytes: Int
    public let initialTailWindowBytes: UInt64

    private let lock = NSLock()
    private var states: [String: JSONLTailState] = [:]

    public init(maxLineBytes: Int = 256 * 1024, initialTailWindowBytes: UInt64 = 64 * 1024) {
        self.maxLineBytes = max(1024, maxLineBytes)
        self.initialTailWindowBytes = max(4096, initialTailWindowBytes)
    }

    public func reset(path: String) {
        lock.lock()
        states.removeValue(forKey: path)
        lock.unlock()
    }

    public func resetAll() {
        lock.lock()
        states.removeAll()
        lock.unlock()
    }

    public func readNewLines(at path: String) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        var st = stat()
        guard stat(path, &st) == 0 else {
            return []
        }

        let currentInode = st.st_ino
        let fileSize = UInt64(max(0, st.st_size))

        var state: JSONLTailState
        if let existing = states[path] {
            if existing.inode != currentInode || fileSize < existing.byteOffset {
                // File rotated, replaced, or truncated: restart cleanly from byte 0.
                state = JSONLTailState(inode: currentInode, byteOffset: 0)
            } else {
                state = existing
            }
        } else {
            if fileSize > initialTailWindowBytes {
                // Cold-start on large file: seek to tail window and discard first partial fragment until '\n'.
                state = JSONLTailState(
                    inode: currentInode,
                    byteOffset: fileSize - initialTailWindowBytes,
                    partialBuffer: Data(),
                    discardUntilNextNewline: true
                )
            } else {
                state = JSONLTailState(inode: currentInode, byteOffset: 0)
            }
        }

        guard fileSize > state.byteOffset else {
            states[path] = state
            return []
        }

        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        if state.byteOffset > 0 {
            let sought = lseek(fd, off_t(state.byteOffset), SEEK_SET)
            if sought < 0 { return [] }
        }

        var newlyRead = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var bytesToRead = fileSize - state.byteOffset

        while bytesToRead > 0 {
            let chunkLen = Int(min(UInt64(buf.count), bytesToRead))
            let n = Darwin.read(fd, &buf, chunkLen)
            if n > 0 {
                newlyRead.append(contentsOf: buf[0..<n])
                bytesToRead -= UInt64(n)
                state.byteOffset += UInt64(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }

        guard !newlyRead.isEmpty else {
            states[path] = state
            return []
        }

        var combined = state.partialBuffer
        combined.append(newlyRead)

        var lines: [Data] = []
        var cursor = combined.startIndex

        while let nl = combined[cursor...].firstIndex(of: 0x0A) {
            if state.discardUntilNextNewline {
                state.discardUntilNextNewline = false
                cursor = combined.index(after: nl)
                continue
            }

            let line = Data(combined[cursor..<nl])
            cursor = combined.index(after: nl)

            if !line.isEmpty && line.count <= maxLineBytes {
                lines.append(line)
            }
        }

        if state.discardUntilNextNewline {
            // Still waiting for the newline that ends the discarded fragment; keep buffer empty.
            state.partialBuffer = Data()
        } else {
            let remainder = Data(combined[cursor...])
            if remainder.count > maxLineBytes {
                // Oversized incomplete line: enter discard-until-newline mode to avoid corrupting next line.
                state.partialBuffer = Data()
                state.discardUntilNextNewline = true
            } else {
                state.partialBuffer = remainder
            }
        }

        states[path] = state
        return lines
    }
}
