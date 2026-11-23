import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionError: Error, Equatable, Sendable {
    case createFailed(code: Int32)
    case releaseFailed(code: Int32)
}

public protocol PowerAssertionBackend: Sendable {
    func createAssertion(level: PowerAssertionLevel, reason: String) -> Result<UInt32, PowerAssertionError>
    func releaseAssertion(id: UInt32) -> Result<Void, PowerAssertionError>
}

public struct IOKitPowerAssertionBackend: PowerAssertionBackend {
    private static let maxReasonLength = 128

    public init() {}

    public func createAssertion(level: PowerAssertionLevel, reason: String) -> Result<UInt32, PowerAssertionError> {
        let assertionType: CFString
        switch level {
        case .systemOnly:
            assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .systemAndDisplay:
            assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        }

        let sanitizedReason = Self.truncateReason(reason)
        var assertionID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            sanitizedReason as CFString,
            &assertionID
        )

        if status == kIOReturnSuccess {
            return .success(assertionID)
        } else {
            return .failure(.createFailed(code: status))
        }
    }

    public func releaseAssertion(id: UInt32) -> Result<Void, PowerAssertionError> {
        let status = IOPMAssertionRelease(id)
        if status == kIOReturnSuccess {
            return .success(())
        } else {
            return .failure(.releaseFailed(code: status))
        }
    }

    public static func truncateReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxReasonLength else { return trimmed }
        return String(trimmed.prefix(maxReasonLength - 1)) + "…"
    }
}
