import CoreServices
import Foundation

private final class FSEventCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable ([String]) -> Void)?

    func setHandler(_ handler: (@Sendable ([String]) -> Void)?) {
        lock.lock()
        _handler = handler
        lock.unlock()
    }

    func currentHandler() -> (@Sendable ([String]) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _handler
    }
}

/// Lightweight directory watcher backed by macOS FSEvents.
/// Acts purely as a dirty-signal trigger on a dedicated serial queue.
public final class FSEventWatcher: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable ([String]) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var streamRef: FSEventStreamRef?
    private var callbackBox: FSEventCallbackBox?

    public init(label: String = "com.codepilot.fsevents") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start(paths: [String], latency: TimeInterval = 0.3, onChange: @escaping ChangeHandler) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard streamRef == nil, !paths.isEmpty else { return false }

        let box = FSEventCallbackBox()
        box.setHandler(onChange)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventCallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let info = clientCallBackInfo else { return }
            let box = Unmanaged<FSEventCallbackBox>.fromOpaque(info).takeUnretainedValue()
            guard let handler = box.currentHandler() else { return }

            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var changedPaths: [String] = []
            changedPaths.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                if let ptr = CFArrayGetValueAtIndex(cfArray, i) {
                    let str = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                    changedPaths.append(str)
                }
            }
            if !changedPaths.isEmpty {
                handler(changedPaths)
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            box.setHandler(nil)
            Unmanaged.passUnretained(box).release()
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            box.setHandler(nil)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        callbackBox = box
        streamRef = stream
        return true
    }

    public func stop() {
        lock.lock()
        let stream = streamRef
        streamRef = nil
        let box = callbackBox
        callbackBox = nil
        lock.unlock()

        box?.setHandler(nil)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
