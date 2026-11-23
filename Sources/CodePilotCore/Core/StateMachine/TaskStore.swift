import Foundation

public enum TaskApplyOutcome: Equatable, Sendable {
    case applied(previousStatus: TaskStatus?, current: AgentTask, shouldNotify: Bool)
    case removed(previous: AgentTask)
    case ignoredOutOfOrder
    case ignoredMissingTarget
    case ignoredInvalidPayload
}

public actor TaskStore {
    public typealias SnapshotListener = @Sendable (TaskStoreSnapshot) async -> Void

    private var tasks: [TaskKey: AgentTask] = [:]
    private let processInspector: any ProcessInspecting
    private let heartbeatTimeout: TimeInterval
    private let waitingUserTimeout: TimeInterval
    private var listeners: [UUID: SnapshotListener] = [:]
    private var snapshotVersion: UInt64 = 0
    private var notifyContinuation: AsyncStream<TaskStoreSnapshot>.Continuation?
    private var notifyTask: Task<Void, Never>?

    public init(
        processInspector: any ProcessInspecting = POSIXProcessInspector(),
        heartbeatTimeout: TimeInterval = 600,
        waitingUserTimeout: TimeInterval = 86_400
    ) {
        self.processInspector = processInspector
        self.heartbeatTimeout = max(1, heartbeatTimeout)
        self.waitingUserTimeout = max(60, waitingUserTimeout)
    }

    deinit {
        notifyContinuation?.finish()
        notifyTask?.cancel()
    }

    @discardableResult
    public func addListener(_ listener: @escaping SnapshotListener) -> UUID {
        ensureNotificationLoop()
        let id = UUID()
        listeners[id] = listener
        return id
    }

    public func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    public func snapshot() -> TaskStoreSnapshot {
        TaskStoreSnapshot(tasks: Array(tasks.values), version: snapshotVersion)
    }

    public func task(for key: TaskKey) -> AgentTask? {
        tasks[key]
    }

    public func runningCount() -> Int {
        tasks.values.filter { $0.status == .running }.count
    }

    public func confirmedRunningCount() -> Int {
        tasks.values.filter { $0.status == .running && $0.provenLive }.count
    }

    @discardableResult
    public func apply(_ event: TaskEvent, now: Date = Date()) -> TaskApplyOutcome {
        let key = event.key

        switch event.type {
        case .remove:
            guard let existing = tasks.removeValue(forKey: key) else {
                return .ignoredMissingTarget
            }
            emitSnapshot()
            return .removed(previous: existing)

        case .heartbeat:
            guard var existing = tasks[key] else {
                return .ignoredMissingTarget
            }
            if isOutOfOrder(event: event, existing: existing) {
                return .ignoredOutOfOrder
            }
            if event.epoch != existing.epoch {
                existing.epoch = event.epoch
                existing.lastSeq = event.seq
            } else if event.seq > existing.lastSeq {
                existing.lastSeq = event.seq
            }
            if event.provenLive {
                existing.provenLive = true
            }
            existing.lastHeartbeatAt = now
            existing.updatedAt = now
            tasks[key] = existing
            emitSnapshot()
            return .applied(previousStatus: existing.status, current: existing, shouldNotify: false)

        case .upsert:
            guard let newStatus = event.status else {
                return .ignoredInvalidPayload
            }

            if var existing = tasks[key] {
                if isOutOfOrder(event: event, existing: existing) {
                    return .ignoredOutOfOrder
                }

                let previousStatus = existing.status
                if event.epoch != existing.epoch {
                    existing.epoch = event.epoch
                    existing.lastSeq = event.seq
                } else if event.seq > existing.lastSeq {
                    existing.lastSeq = event.seq
                }
                existing.status = newStatus
                existing.provenLive = event.provenLive
                if let title = event.title, !title.isEmpty {
                    existing.title = title
                }
                if let message = event.message {
                    existing.message = message
                }
                if let bundleId = event.appBundleId {
                    existing.appBundleId = bundleId
                }
                if let deepLink = event.deepLinkURL {
                    existing.deepLinkURL = deepLink
                }
                if let cwd = event.cwd {
                    existing.cwd = cwd
                }
                if let pid = event.pid, pid != existing.pid {
                    existing.pid = pid
                    existing.pidStartTimeMicros = processInspector.startTimeMicros(for: pid)
                }
                if previousStatus.isFinished && newStatus == .running {
                    existing.startedAt = now
                }
                existing.updatedAt = now
                existing.lastHeartbeatAt = now

                tasks[key] = existing
                emitSnapshot()
                return .applied(previousStatus: previousStatus, current: existing, shouldNotify: !event.isPriming)
            } else {
                let pidStart = event.pid.flatMap { processInspector.startTimeMicros(for: $0) }
                let created = AgentTask(
                    key: key,
                    epoch: event.epoch,
                    lastSeq: event.seq,
                    title: (event.title?.isEmpty == false ? event.title! : "\(event.source.displayName) 任务"),
                    status: newStatus,
                    provenLive: event.provenLive,
                    startedAt: event.timestamp <= now ? event.timestamp : now,
                    updatedAt: now,
                    lastHeartbeatAt: now,
                    appBundleId: event.appBundleId,
                    deepLinkURL: event.deepLinkURL,
                    cwd: event.cwd,
                    pid: event.pid,
                    pidStartTimeMicros: pidStart,
                    message: event.message
                )
                tasks[key] = created
                emitSnapshot()
                return .applied(previousStatus: nil, current: created, shouldNotify: !event.isPriming)
            }
        }
    }

    /// Tiered read acknowledgement:
    /// - `.seenByApp` never deletes tasks (prevents false dismissals in IDEs).
    /// - `.openedSession` / `.userConfirmed` removes finished tasks.
    @discardableResult
    public func acknowledgeRead(_ level: ReadAckLevel) -> Bool {
        switch level {
        case .seenByApp:
            return false
        case .openedSession(let key), .userConfirmed(let key):
            guard let existing = tasks[key], existing.status.isFinished else {
                return false
            }
            tasks.removeValue(forKey: key)
            emitSnapshot()
            return true
        }
    }

    @discardableResult
    public func sweepZombies(now: Date = Date()) -> [AgentTask] {
        var archived: [AgentTask] = []

        for (key, var task) in tasks where task.status == .running || task.status == .waitingUser {
            var shouldArchive = false
            var archiveReason: String?
            let timeout = (task.status == .running) ? heartbeatTimeout : waitingUserTimeout

            if let pid = task.pid {
                switch processInspector.probe(pid: pid, expectedStartTimeMicros: task.pidStartTimeMicros) {
                case .exited:
                    shouldArchive = true
                    archiveReason = "进程已退出，已自动归档"
                case .alive:
                    shouldArchive = false
                case .permissionDenied, .unknown:
                    if now.timeIntervalSince(task.lastHeartbeatAt) >= timeout {
                        shouldArchive = true
                        archiveReason = "长时间无更新，已自动归档"
                    }
                }
            } else if now.timeIntervalSince(task.lastHeartbeatAt) >= timeout {
                shouldArchive = true
                archiveReason = "长时间无更新，已自动归档"
            }

            if shouldArchive {
                task.status = .completed
                task.provenLive = false
                task.updatedAt = now
                if let archiveReason {
                    task.message = archiveReason
                }
                tasks[key] = task
                archived.append(task)
            }
        }

        if !archived.isEmpty {
            emitSnapshot()
        }
        return archived
    }

    @discardableResult
    public func clearFinished() -> Int {
        let keysToRemove = tasks.values.filter { $0.status.isFinished }.map(\.key)
        for key in keysToRemove {
            tasks.removeValue(forKey: key)
        }
        if !keysToRemove.isEmpty {
            emitSnapshot()
        }
        return keysToRemove.count
    }

    private func isOutOfOrder(event: TaskEvent, existing: AgentTask) -> Bool {
        guard event.epoch == existing.epoch else {
            return false
        }
        if existing.lastSeq > 0 && event.seq < existing.lastSeq {
            return true
        }
        return false
    }

    private func ensureNotificationLoop() {
        guard notifyContinuation == nil else { return }
        let (stream, continuation) = AsyncStream<TaskStoreSnapshot>.makeStream()
        notifyContinuation = continuation
        notifyTask = Task { [weak self] in
            for await snap in stream {
                guard let self else { break }
                let currentListeners = await self.currentListeners()
                for listener in currentListeners {
                    await listener(snap)
                }
            }
        }
    }

    private func currentListeners() -> [SnapshotListener] {
        Array(listeners.values)
    }

    private func emitSnapshot() {
        snapshotVersion &+= 1
        guard let continuation = notifyContinuation else { return }
        continuation.yield(snapshot())
    }
}
