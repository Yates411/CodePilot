import Foundation

public actor PowerAssertionManager {
    public typealias SnapshotListener = @Sendable (PowerManagerSnapshot) async -> Void

    private let backend: any PowerAssertionBackend
    private let clock: ContinuousClock
    private var policy: PowerPolicy

    private var leases: [PowerLeaseKind: PowerLease] = [:]
    private var currentAssertionID: UInt32?
    private var currentLevel: PowerAssertionLevel?
    private var lastError: String?

    private var runningTaskCount: Int = 0
    private var lastMatchedProcesses: [String] = []
    private var graceDeadline: ContinuousClock.Instant?
    private var graceTask: Task<Void, Never>?
    private var expiryTasks: [PowerLeaseKind: Task<Void, Never>] = [:]

    private var isAutoBlockedByLowBattery: Bool = false
    private var listeners: [UUID: SnapshotListener] = [:]
    private var snapshotVersion: UInt64 = 0
    private var notifyContinuation: AsyncStream<PowerManagerSnapshot>.Continuation?
    private var notifyTask: Task<Void, Never>?

    public init(
        backend: any PowerAssertionBackend = IOKitPowerAssertionBackend(),
        policy: PowerPolicy = PowerPolicy(),
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.backend = backend
        self.policy = policy.normalized()
        self.clock = clock
    }

    deinit {
        graceTask?.cancel()
        for task in expiryTasks.values {
            task.cancel()
        }
        notifyContinuation?.finish()
        notifyTask?.cancel()
        if let id = currentAssertionID {
            if case .failure(let error) = backend.releaseAssertion(id: id) {
                fputs("[CodePilot] PowerAssertionManager deinit failed to release assertion \(id): \(error)\n", stderr)
            }
        }
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

    public func snapshot() -> PowerManagerSnapshot {
        PowerManagerSnapshot(
            version: snapshotVersion,
            activeLevel: currentLevel,
            activeLeases: Array(leases.values).sorted { $0.kind.priority > $1.kind.priority },
            isAutoBlockedByLowBattery: isAutoBlockedByLowBattery,
            graceDeadline: graceDeadline,
            lastError: lastError
        )
    }

    public func updatePolicy(_ newPolicy: PowerPolicy) {
        policy = newPolicy.normalized()
        if !policy.autoKeepAwakeEnabled {
            cancelGraceTimer()
            leases.removeValue(forKey: .aiAuto)
        } else if runningTaskCount > 0 && !isAutoBlockedByLowBattery {
            acquireAutoLease(now: clock.now)
        }
        reconcile(now: clock.now)
    }

    public func acquireManualIndefinite(level: PowerAssertionLevel = .systemOnly, reason: String = "手动防休眠") {
        let now = clock.now
        leases[.manualIndefinite] = PowerLease(
            kind: .manualIndefinite,
            reason: reason,
            level: level,
            createdAt: now,
            expiresAt: nil
        )
        reconcile(now: now)
    }

    public func releaseManualIndefinite() {
        leases.removeValue(forKey: .manualIndefinite)
        reconcile(now: clock.now)
    }

    @discardableResult
    public func acquireManualTimed(
        duration: Duration,
        level: PowerAssertionLevel = .systemOnly,
        reason: String = "定时防休眠"
    ) -> UUID {
        let id = UUID()
        let kind = PowerLeaseKind.manualTimed(id: id)
        let now = clock.now
        let safeDuration = duration < .zero ? .zero : duration
        let deadline = now.advanced(by: safeDuration)

        leases[kind] = PowerLease(
            kind: kind,
            reason: reason,
            level: level,
            createdAt: now,
            expiresAt: deadline
        )
        scheduleExpiry(for: kind, deadline: deadline)
        reconcile(now: now)
        return id
    }

    public func release(kind: PowerLeaseKind) {
        expiryTasks.removeValue(forKey: kind)?.cancel()
        if kind == .aiAuto {
            cancelGraceTimer()
        }
        leases.removeValue(forKey: kind)
        reconcile(now: clock.now)
    }

    public func syncProcessRules(matchedProcesses: [String]) {
        lastMatchedProcesses = matchedProcesses
        let now = clock.now
        let desiredSet = Set(matchedProcesses)

        // Remove stale processRule leases
        for kind in Array(leases.keys) {
            if case .processRule(let name) = kind, !desiredSet.contains(name) || isAutoBlockedByLowBattery {
                leases.removeValue(forKey: kind)
            }
        }

        if !isAutoBlockedByLowBattery {
            for name in matchedProcesses {
                let kind = PowerLeaseKind.processRule(name: name)
                if leases[kind] == nil {
                    leases[kind] = PowerLease(
                        kind: kind,
                        reason: "进程防休眠：\(name)",
                        level: policy.autoLevel,
                        createdAt: now,
                        expiresAt: nil
                    )
                }
            }
        }
        reconcile(now: now)
    }

    public func updateRunningTaskCount(_ count: Int, reason: String = "AI 任务运行中") {
        let clamped = max(0, count)
        runningTaskCount = clamped
        let now = clock.now

        guard policy.autoKeepAwakeEnabled else { return }

        if clamped > 0 {
            cancelGraceTimer()
            if !isAutoBlockedByLowBattery {
                acquireAutoLease(now: now, reason: reason)
            }
            reconcile(now: now)
        } else {
            if leases[.aiAuto] != nil {
                if policy.gracePeriod <= .zero {
                    leases.removeValue(forKey: .aiAuto)
                    reconcile(now: now)
                } else {
                    startGraceTimer(from: now)
                    emitSnapshot()
                }
            }
        }
    }

    public func handleBatteryUpdate(_ status: BatteryStatus) {
        let now = clock.now
        if status.isOnBattery && status.percentage <= policy.lowBatteryThreshold {
            if !isAutoBlockedByLowBattery {
                isAutoBlockedByLowBattery = true
                cancelGraceTimer()
                leases.removeValue(forKey: .aiAuto)
                for kind in Array(leases.keys) {
                    if case .processRule = kind {
                        leases.removeValue(forKey: kind)
                    }
                }
                if policy.lowBatteryCancelsManual {
                    for kind in Array(leases.keys) where kind.isManual {
                        expiryTasks.removeValue(forKey: kind)?.cancel()
                        leases.removeValue(forKey: kind)
                    }
                }
                reconcile(now: now)
            }
        } else if !status.isOnBattery || status.percentage >= (policy.lowBatteryThreshold + policy.lowBatteryHysteresis) {
            if isAutoBlockedByLowBattery {
                isAutoBlockedByLowBattery = false
                if policy.autoKeepAwakeEnabled && runningTaskCount > 0 {
                    acquireAutoLease(now: now)
                }
                for name in lastMatchedProcesses {
                    let kind = PowerLeaseKind.processRule(name: name)
                    leases[kind] = PowerLease(
                        kind: kind,
                        reason: "进程防休眠：\(name)",
                        level: policy.autoLevel,
                        createdAt: now,
                        expiresAt: nil
                    )
                }
                reconcile(now: now)
            }
        }
    }

    public func handleSystemWake() {
        let now = clock.now

        for (kind, lease) in Array(leases) {
            if lease.isExpired(at: now) {
                expiryTasks.removeValue(forKey: kind)?.cancel()
                leases.removeValue(forKey: kind)
            } else if let deadline = lease.expiresAt {
                scheduleExpiry(for: kind, deadline: deadline)
            }
        }

        if let deadline = graceDeadline {
            if now >= deadline {
                cancelGraceTimer()
                leases.removeValue(forKey: .aiAuto)
            } else {
                rescheduleGraceTimer(until: deadline)
            }
        }

        reconcile(now: now, forceRebuild: true)
    }

    public func releaseAll() {
        cancelGraceTimer()
        for task in expiryTasks.values {
            task.cancel()
        }
        expiryTasks.removeAll()
        leases.removeAll()
        reconcile(now: clock.now)
    }

    private func acquireAutoLease(now: ContinuousClock.Instant, reason: String = "AI 任务运行中") {
        leases[.aiAuto] = PowerLease(
            kind: .aiAuto,
            reason: reason,
            level: policy.autoLevel,
            createdAt: now,
            expiresAt: nil
        )
    }

    private func startGraceTimer(from now: ContinuousClock.Instant) {
        let deadline = now.advanced(by: policy.gracePeriod)
        graceDeadline = deadline
        rescheduleGraceTimer(until: deadline)
    }

    private func rescheduleGraceTimer(until deadline: ContinuousClock.Instant) {
        graceTask?.cancel()
        graceTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(until: deadline, tolerance: .milliseconds(50))
            } catch {
                return
            }
            await self?.onGracePeriodElapsed(expectedDeadline: deadline)
        }
    }

    private func onGracePeriodElapsed(expectedDeadline: ContinuousClock.Instant) {
        guard graceDeadline == expectedDeadline else { return }
        graceDeadline = nil
        graceTask = nil
        if runningTaskCount == 0 {
            leases.removeValue(forKey: .aiAuto)
            reconcile(now: clock.now)
        }
    }

    private func cancelGraceTimer() {
        graceTask?.cancel()
        graceTask = nil
        graceDeadline = nil
    }

    private func scheduleExpiry(for kind: PowerLeaseKind, deadline: ContinuousClock.Instant) {
        expiryTasks[kind]?.cancel()
        expiryTasks[kind] = Task { [weak self, clock] in
            do {
                try await clock.sleep(until: deadline, tolerance: .milliseconds(50))
            } catch {
                return
            }
            await self?.onLeaseExpired(kind: kind, expectedDeadline: deadline)
        }
    }

    private func onLeaseExpired(kind: PowerLeaseKind, expectedDeadline: ContinuousClock.Instant) {
        guard let lease = leases[kind], lease.expiresAt == expectedDeadline else { return }
        expiryTasks.removeValue(forKey: kind)
        leases.removeValue(forKey: kind)
        reconcile(now: clock.now)
    }

    private func reconcile(now: ContinuousClock.Instant, forceRebuild: Bool = false) {
        for (kind, lease) in Array(leases) where lease.isExpired(at: now) {
            expiryTasks.removeValue(forKey: kind)?.cancel()
            leases.removeValue(forKey: kind)
        }

        let targetLevel = leases.values.map(\.level).max()
        let primaryReason = leases.values.max(by: { $0.kind.priority < $1.kind.priority })?.reason ?? "CodePilot Keep-Awake"

        if let targetLevel {
            if forceRebuild || currentLevel != targetLevel || currentAssertionID == nil {
                let previousID = currentAssertionID
                switch backend.createAssertion(level: targetLevel, reason: "CodePilot: \(primaryReason)") {
                case .success(let newID):
                    currentAssertionID = newID
                    currentLevel = targetLevel
                    lastError = nil
                    if let previousID {
                        _ = backend.releaseAssertion(id: previousID)
                    }
                case .failure(let error):
                    lastError = "IOKit 断言创建失败: \(error)"
                }
            }
        } else {
            if let existingID = currentAssertionID {
                switch backend.releaseAssertion(id: existingID) {
                case .success:
                    currentAssertionID = nil
                    currentLevel = nil
                    lastError = nil
                case .failure(let error):
                    lastError = "IOKit 断言释放失败: \(error)"
                    currentAssertionID = nil
                    currentLevel = nil
                }
            } else {
                currentLevel = nil
            }
        }

        emitSnapshot()
    }

    private func ensureNotificationLoop() {
        guard notifyContinuation == nil else { return }
        let (stream, continuation) = AsyncStream<PowerManagerSnapshot>.makeStream()
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
