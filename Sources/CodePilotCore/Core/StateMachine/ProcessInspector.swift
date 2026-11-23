import Darwin
import Foundation

public enum ProcessProbeResult: Equatable, Sendable {
    case alive
    case exited
    case permissionDenied
    case unknown
}

public protocol ProcessInspecting: Sendable {
    func startTimeMicros(for pid: Int32) -> UInt64?
    func probe(pid: Int32, expectedStartTimeMicros: UInt64?) -> ProcessProbeResult
}

public struct POSIXProcessInspector: ProcessInspecting {
    public init() {}

    public func startTimeMicros(for pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    public func probe(pid: Int32, expectedStartTimeMicros: UInt64?) -> ProcessProbeResult {
        guard pid > 0 else { return .exited }

        if kill(pid, 0) != 0 {
            switch errno {
            case ESRCH:
                return .exited
            case EPERM:
                return .permissionDenied
            default:
                return .unknown
            }
        }

        if let expected = expectedStartTimeMicros {
            guard let actual = startTimeMicros(for: pid) else {
                // Unable to verify process start time; do not blindly trust PID liveness.
                return .unknown
            }
            if actual != expected {
                // PID has been reused by a newer process, so the original process has exited.
                return .exited
            }
        }

        return .alive
    }
}
