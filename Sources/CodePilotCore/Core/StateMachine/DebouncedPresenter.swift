import Foundation

public struct RepeatReminderPolicy: Equatable, Sendable {
    public var enabled: Bool
    public var interval: Duration
    public var maxRepeats: Int

    public init(enabled: Bool = true, interval: Duration = .seconds(300), maxRepeats: Int = 3) {
        self.enabled = enabled
        self.interval = interval < .milliseconds(10) ? .milliseconds(10) : interval
        self.maxRepeats = max(0, maxRepeats)
    }
}

/// Debounces transition alerts (e.g. running -> waiting_user / completed) and schedules
/// gentle repeat reminders while a task stays in `waiting_user`.
public actor DebouncedAlertCoordinator {
    public typealias AlertHandler = @Sendable (AgentTask, Bool) async -> Void

    private let delay: Duration
    private let clock: ContinuousClock
    private var repeatPolicy: RepeatReminderPolicy
    private var pendingTasks: [TaskKey: Task<Void, Never>] = [:]
    private var pendingSnapshots: [TaskKey: AgentTask] = [:]
    private var repeatTasks: [TaskKey: Task<Void, Never>] = [:]
    private var repeatSnapshots: [TaskKey: AgentTask] = [:]
    private let onAlert: AlertHandler

    public init(
        delay: Duration = .milliseconds(2500),
        repeatPolicy: RepeatReminderPolicy = RepeatReminderPolicy(),
        clock: ContinuousClock = ContinuousClock(),
        onAlert: @escaping AlertHandler
    ) {
        self.delay = delay
        self.repeatPolicy = repeatPolicy
        self.clock = clock
        self.onAlert = onAlert
    }

    deinit {
        for task in pendingTasks.values { task.cancel() }
        for task in repeatTasks.values { task.cancel() }
    }

    public func updateRepeatPolicy(_ policy: RepeatReminderPolicy) {
        self.repeatPolicy = policy
        if !policy.enabled || policy.maxRepeats == 0 {
            for task in repeatTasks.values { task.cancel() }
            repeatTasks.removeAll()
            repeatSnapshots.removeAll()
        }
    }

    public func handleTransition(previousStatus: TaskStatus?, current: AgentTask, shouldNotify: Bool = true) {
        let key = current.key

        // Resuming running or finishing cancels any repeat reminders for waiting_user.
        if current.status != .waitingUser {
            cancelRepeat(for: key)
        }

        if current.status == .running {
            pendingTasks.removeValue(forKey: key)?.cancel()
            pendingSnapshots.removeValue(forKey: key)
            return
        }

        // Refresh pending or repeat snapshot if still in same status.
        if previousStatus == current.status {
            if pendingTasks[key] != nil {
                pendingSnapshots[key] = current
            }
            if repeatTasks[key] != nil {
                repeatSnapshots[key] = current
            }
            return
        }

        guard shouldNotify else { return }
        guard current.status == .waitingUser || current.status == .completed || current.status == .error else {
            return
        }

        pendingTasks.removeValue(forKey: key)?.cancel()
        pendingSnapshots[key] = current
        pendingTasks[key] = Task { [weak self, clock, delay] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.fireInitialAlert(for: key)
        }
    }

    /// Tiered read ack (`.seenByApp`): silences repeat reminders for a source without deleting tasks.
    public func silenceReminders(for source: AgentSource) {
        for key in Array(repeatTasks.keys) where key.source == source {
            cancelRepeat(for: key)
        }
    }

    public func cancelAll() {
        for task in pendingTasks.values { task.cancel() }
        for task in repeatTasks.values { task.cancel() }
        pendingTasks.removeAll()
        pendingSnapshots.removeAll()
        repeatTasks.removeAll()
        repeatSnapshots.removeAll()
    }

    private func fireInitialAlert(for key: TaskKey) async {
        pendingTasks.removeValue(forKey: key)
        guard let latest = pendingSnapshots.removeValue(forKey: key) else { return }
        await onAlert(latest, false)

        if latest.status == .waitingUser && repeatPolicy.enabled && repeatPolicy.maxRepeats > 0 {
            scheduleRepeatReminders(for: latest)
        }
    }

    private func scheduleRepeatReminders(for task: AgentTask) {
        let key = task.key
        cancelRepeat(for: key)
        repeatSnapshots[key] = task
        let policy = repeatPolicy
        repeatTasks[key] = Task { [weak self, clock] in
            for _ in 0..<policy.maxRepeats {
                do {
                    try await clock.sleep(for: policy.interval)
                } catch {
                    return
                }
                guard let self else { return }
                let stillPending = await self.fireRepeatAlert(for: key)
                if !stillPending { return }
            }
            await self?.cancelRepeat(for: key)
        }
    }

    private func fireRepeatAlert(for key: TaskKey) async -> Bool {
        guard let latest = repeatSnapshots[key], latest.status == .waitingUser else {
            return false
        }
        await onAlert(latest, true)
        return true
    }

    private func cancelRepeat(for key: TaskKey) {
        repeatTasks.removeValue(forKey: key)?.cancel()
        repeatSnapshots.removeValue(forKey: key)
    }
}
