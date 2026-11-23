import Darwin
import Foundation

/// Lightweight, fork-free process scanner using Darwin `libproc` (`proc_listallpids` + `proc_name`).
/// Matches running process names case-insensitively against user-configured keep-awake rules.
public final class ProcessRuleMonitor: Sendable {
    public init() {}

    public func runningProcessNames() -> Set<String> {
        let initialCount = proc_listallpids(nil, 0)
        guard initialCount > 0 else { return [] }

        let capacity = Int(initialCount) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytesReturned = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_listallpids(base, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        guard bytesReturned > 0 else { return [] }

        let actualCount = min(capacity, Int(bytesReturned) / MemoryLayout<pid_t>.stride)
        var names = Set<String>()
        names.reserveCapacity(actualCount)

        var nameBuf = [CChar](repeating: 0, count: 256)
        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = nameBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return 0 }
                return proc_name(pid, base, UInt32(buf.count))
            }
            if len > 0 {
                let bytes = nameBuf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
                if let name = String(bytes: bytes, encoding: .utf8), !name.isEmpty {
                    names.insert(name.lowercased())
                }
            }
        }
        return names
    }

    public func matchingRules(watchedNames: [String]) -> [String] {
        let normalizedRules = watchedNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedRules.isEmpty else { return [] }

        let active = runningProcessNames()
        var matched: [String] = []
        var seen = Set<String>()
        for rule in normalizedRules {
            let key = rule.lowercased()
            if active.contains(key), !seen.contains(key) {
                seen.insert(key)
                matched.append(rule)
            }
        }
        return matched
    }
}
