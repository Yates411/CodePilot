import Foundation

/// Coalesces bursty FSEvents notifications by key using a monotonic ContinuousClock debounce,
/// serializing refreshes and dropping stale generations.
public actor AdapterRefreshCoalescer {
    private let delay: Duration
    private let clock: ContinuousClock
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UInt64] = [:]

    public init(delay: Duration = .milliseconds(300), clock: ContinuousClock = ContinuousClock()) {
        self.delay = delay
        self.clock = clock
    }

    deinit {
        for task in pendingTasks.values {
            task.cancel()
        }
    }

    public func schedule(key: String, action: @escaping @Sendable () async -> Void) {
        let nextGen = (generations[key] ?? 0) &+ 1
        generations[key] = nextGen
        pendingTasks[key]?.cancel()

        pendingTasks[key] = Task { [weak self, clock, delay] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            let isLatest = await self.isCurrent(key: key, generation: nextGen)
            guard isLatest else { return }
            await action()
            await self.clearIfCurrent(key: key, generation: nextGen)
        }
    }

    public func cancelAll() {
        for task in pendingTasks.values {
            task.cancel()
        }
        pendingTasks.removeAll()
        generations.removeAll()
    }

    private func isCurrent(key: String, generation: UInt64) -> Bool {
        generations[key] == generation
    }

    private func clearIfCurrent(key: String, generation: UInt64) {
        if generations[key] == generation {
            pendingTasks.removeValue(forKey: key)
        }
    }
}
