import Foundation
import IOKit.ps

private final class BatteryCallbackBox {
    var handler: (@Sendable (BatteryStatus) -> Void)?
}

@MainActor
public final class BatteryMonitor {
    public typealias ChangeHandler = @Sendable (BatteryStatus) -> Void

    private var runLoopSource: CFRunLoopSource?
    private var callbackBox: BatteryCallbackBox?

    public init() {}

    isolated deinit {
        stop()
    }

    public nonisolated static func currentStatus() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return nil
        }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let powerState = desc[kIOPSPowerSourceStateKey as String] as? String
            let isOnBattery = (powerState == (kIOPSBatteryPowerValue as String))
            if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int,
               maxCap > 0 {
                let pct = Int((Double(current) / Double(maxCap) * 100.0).rounded())
                return BatteryStatus(isOnBattery: isOnBattery, percentage: pct)
            }
        }
        return nil
    }

    public func start(onChange: @escaping ChangeHandler) {
        guard runLoopSource == nil else { return }

        let box = BatteryCallbackBox()
        box.handler = onChange
        callbackBox = box

        let context = Unmanaged.passRetained(box).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let box = Unmanaged<BatteryCallbackBox>.fromOpaque(context).takeUnretainedValue()
            guard let handler = box.handler, let status = BatteryMonitor.currentStatus() else { return }
            handler(status)
        }

        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        } else {
            box.handler = nil
            Unmanaged.passUnretained(box).release()
            callbackBox = nil
        }

        // Dispatch initial status after registration completes (no lock held).
        if let initial = Self.currentStatus() {
            onChange(initial)
        }
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        if let box = callbackBox {
            box.handler = nil
            Unmanaged.passUnretained(box).release()
            callbackBox = nil
        }
    }
}
