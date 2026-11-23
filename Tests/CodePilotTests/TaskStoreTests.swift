import CodePilotCore
import Foundation

final class MockProcessInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var startTimes: [Int32: UInt64] = [:]
    private var probes: [Int32: ProcessProbeResult] = [:]

    func set(pid: Int32, startTime: UInt64?, probe: ProcessProbeResult) {
        lock.lock()
        defer { lock.unlock() }
        if let startTime {
            startTimes[pid] = startTime
        } else {
            startTimes.removeValue(forKey: pid)
        }
        probes[pid] = probe
    }

    func startTimeMicros(for pid: Int32) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return startTimes[pid]
    }

    func probe(pid: Int32, expectedStartTimeMicros: UInt64?) -> ProcessProbeResult {
        lock.lock()
        defer { lock.unlock() }
        if let result = probes[pid] {
            if result == .alive,
               let expected = expectedStartTimeMicros,
               let actual = startTimes[pid],
               actual != expected {
                return .exited
            }
            return result
        }
        return .exited
    }
}

enum TaskStoreTests {
    static func epochAndSequenceOrdering() async throws {
        let store = TaskStore()
        let key = TaskKey(source: .antigravity, sessionId: "s1", taskId: "t1")

        let r1 = await store.apply(TaskEvent(
            type: .upsert, source: .antigravity, epoch: "e1", sessionId: "s1", taskId: "t1",
            seq: 10, status: .running, title: "实现状态机"
        ))
        guard case .applied(nil, let t1, true) = r1 else {
            throw TestFailure.expectationFailed("Expected applied", file: #file, line: #line)
        }
        try expect(t1.status == .running)
        try expect(t1.lastSeq == 10)

        let r2 = await store.apply(TaskEvent(
            type: .upsert, source: .antigravity, epoch: "e1", sessionId: "s1", taskId: "t1",
            seq: 9, status: .completed
        ))
        try expect(r2 == .ignoredOutOfOrder)
        try expect(await store.task(for: key)?.status == .running)

        let r3 = await store.apply(TaskEvent(
            type: .upsert, source: .antigravity, epoch: "e2", sessionId: "s1", taskId: "t1",
            seq: 1, status: .waitingUser, message: "请确认方案"
        ))
        guard case .applied(.running, let t3, true) = r3 else {
            throw TestFailure.expectationFailed("Expected applied on new epoch", file: #file, line: #line)
        }
        try expect(t3.status == .waitingUser)
        try expect(t3.epoch == "e2")
        try expect(t3.lastSeq == 1)
    }

    static func zombieSweepPidExitedAndReused() async throws {
        let inspector = MockProcessInspector()
        inspector.set(pid: 1001, startTime: 500_000, probe: .alive)
        inspector.set(pid: 1002, startTime: 600_000, probe: .alive)

        let store = TaskStore(processInspector: inspector, heartbeatTimeout: 600)
        let t0 = Date(timeIntervalSince1970: 1_000)

        _ = await store.apply(TaskEvent(
            type: .upsert, source: .kimiCode, epoch: "e1", sessionId: "s1", taskId: "t1",
            seq: 1, status: .running, title: "已退出进程", pid: 1001
        ), now: t0)
        _ = await store.apply(TaskEvent(
            type: .upsert, source: .kimiCode, epoch: "e1", sessionId: "s2", taskId: "t1",
            seq: 1, status: .running, title: "PID 复用进程", pid: 1002
        ), now: t0)

        inspector.set(pid: 1001, startTime: nil, probe: .exited)
        inspector.set(pid: 1002, startTime: 999_999, probe: .alive)

        let archived = await store.sweepZombies(now: t0.addingTimeInterval(30))
        try expect(archived.count == 2)
        try expect(await store.runningCount() == 0)
    }

    static func permissionDeniedFallsBackToHeartbeatTimeout() async throws {
        let inspector = MockProcessInspector()
        inspector.set(pid: 2001, startTime: nil, probe: .permissionDenied)

        let store = TaskStore(processInspector: inspector, heartbeatTimeout: 300)
        let t0 = Date(timeIntervalSince1970: 1_000)

        _ = await store.apply(TaskEvent(
            type: .upsert, source: .workbuddy, epoch: "e1", sessionId: "s1", taskId: "t1",
            seq: 1, status: .running, title: "跨权限任务", pid: 2001
        ), now: t0)

        let early = await store.sweepZombies(now: t0.addingTimeInterval(100))
        try expect(early.isEmpty)
        try expect(await store.runningCount() == 1)

        let late = await store.sweepZombies(now: t0.addingTimeInterval(301))
        try expect(late.count == 1)
        try expect(await store.runningCount() == 0)
    }

    static func clearFinishedTasks() async throws {
        let store = TaskStore()
        _ = await store.apply(TaskEvent(type: .upsert, source: .antigravity, epoch: "e", sessionId: "s1", seq: 1, status: .running))
        _ = await store.apply(TaskEvent(type: .upsert, source: .antigravity, epoch: "e", sessionId: "s2", seq: 1, status: .waitingUser))
        _ = await store.apply(TaskEvent(type: .upsert, source: .antigravity, epoch: "e", sessionId: "s3", seq: 1, status: .completed))
        _ = await store.apply(TaskEvent(type: .upsert, source: .antigravity, epoch: "e", sessionId: "s4", seq: 1, status: .error))

        let removed = await store.clearFinished()
        try expect(removed == 2)
        let snap = await store.snapshot()
        try expect(snap.tasks.count == 2)
        try expect(snap.runningCount == 1)
        try expect(snap.waitingUserCount == 1)
    }

    static func seqZeroCannotResetPositiveSeq() async throws {
        let store = TaskStore()
        let key = TaskKey(source: .antigravity, sessionId: "s1", taskId: "t1")

        _ = await store.apply(TaskEvent(
            type: .upsert, source: .antigravity, epoch: "e1", sessionId: "s1", taskId: "t1",
            seq: 10, status: .running, title: "正常任务"
        ))
        let zeroResult = await store.apply(TaskEvent(
            type: .upsert, source: .antigravity, epoch: "e1", sessionId: "s1", taskId: "t1",
            seq: 0, status: .completed
        ))
        try expect(zeroResult == .ignoredOutOfOrder)
        try expect(await store.task(for: key)?.lastSeq == 10)
        try expect(await store.task(for: key)?.status == .running)
    }

    static func waitingUserArchivedWhenProcessExits() async throws {
        let inspector = MockProcessInspector()
        inspector.set(pid: 3001, startTime: 700_000, probe: .alive)
        let store = TaskStore(processInspector: inspector, heartbeatTimeout: 600, waitingUserTimeout: 86_400)
        let t0 = Date(timeIntervalSince1970: 1_000)

        _ = await store.apply(TaskEvent(
            type: .upsert, source: .antigravity, epoch: "e1", sessionId: "s1", taskId: "t1",
            seq: 1, status: .waitingUser, title: "等待确认", pid: 3001
        ), now: t0)

        inspector.set(pid: 3001, startTime: nil, probe: .exited)
        let archived = await store.sweepZombies(now: t0.addingTimeInterval(30))
        try expect(archived.count == 1)
        try expect(await store.snapshot().waitingUserCount == 0)
    }

    static func debouncedAlertCancelsWhenTaskResumesRunning() async throws {
        actor AlertBox {
            var alerted: [TaskStatus] = []
            func record(_ s: TaskStatus) { alerted.append(s) }
            func all() -> [TaskStatus] { alerted }
        }
        let box = AlertBox()
        let coordinator = DebouncedAlertCoordinator(
            delay: .milliseconds(100),
            repeatPolicy: RepeatReminderPolicy(enabled: true, interval: .milliseconds(120), maxRepeats: 2)
        ) { task, _ in
            await box.record(task.status)
        }
        let key = TaskKey(source: .antigravity, sessionId: "s1", taskId: "t1")
        let now = Date()
        let completedTask = AgentTask(
            key: key, epoch: "e1", lastSeq: 2, title: "T", status: .completed,
            startedAt: now, updatedAt: now, lastHeartbeatAt: now
        )
        let runningTask = AgentTask(
            key: key, epoch: "e1", lastSeq: 3, title: "T", status: .running,
            startedAt: now, updatedAt: now, lastHeartbeatAt: now
        )
        let waitingTask = AgentTask(
            key: key, epoch: "e1", lastSeq: 4, title: "T", status: .waitingUser,
            startedAt: now, updatedAt: now, lastHeartbeatAt: now
        )

        // Transition to completed, then resume running before debounce window -> must NOT fire
        await coordinator.handleTransition(previousStatus: .running, current: completedTask)
        try await Task.sleep(for: .milliseconds(35))
        await coordinator.handleTransition(previousStatus: .completed, current: runningTask)
        try await Task.sleep(for: .milliseconds(120))
        try expect(await box.all().isEmpty)

        // Transition to waitingUser -> initial alert + 1 repeat, then silenceReminders stops further repeats
        await coordinator.handleTransition(previousStatus: .running, current: waitingTask)
        try await Task.sleep(for: .milliseconds(260))
        await coordinator.silenceReminders(for: .antigravity)
        let countAfterSilence = await box.all().count
        try expect(countAfterSilence >= 2)
        try await Task.sleep(for: .milliseconds(160))
        try expect(await box.all().count == countAfterSilence)
    }

    static func primingThreeWayAndTieredReadAck() async throws {
        let store = TaskStore()
        let key1 = TaskKey(source: .deepseekHarness, sessionId: "old", taskId: "main")
        let key2 = TaskKey(source: .deepseekHarness, sessionId: "live", taskId: "main")
        let key3 = TaskKey(source: .deepseekHarness, sessionId: "done", taskId: "main")

        // Unconfirmed historical running during priming -> shouldNotify=false, NOT counted in confirmedRunningCount
        let r1 = await store.apply(TaskEvent(
            type: .upsert, source: .deepseekHarness, epoch: "e1", sessionId: "old",
            seq: 1, status: .running, isPriming: true, provenLive: false
        ))
        guard case .applied(_, _, let notify1) = r1 else {
            throw TestFailure.expectationFailed("Expected applied", file: #file, line: #line)
        }
        try expect(notify1 == false)
        try expect(await store.runningCount() == 1)
        try expect(await store.confirmedRunningCount() == 0)

        // Proven-live running -> counted in confirmedRunningCount
        _ = await store.apply(TaskEvent(
            type: .upsert, source: .deepseekHarness, epoch: "e1", sessionId: "live",
            seq: 2, status: .running, isPriming: true, provenLive: true
        ))
        try expect(await store.confirmedRunningCount() == 1)

        // Completed task -> seenByApp does NOT remove; openedSession removes
        _ = await store.apply(TaskEvent(
            type: .upsert, source: .deepseekHarness, epoch: "e1", sessionId: "done",
            seq: 3, status: .completed, isPriming: false, provenLive: false
        ))
        try expect(await store.acknowledgeRead(.seenByApp(.deepseekHarness)) == false)
        try expect(await store.task(for: key3) != nil)
        try expect(await store.acknowledgeRead(.openedSession(key3)) == true)
        try expect(await store.task(for: key3) == nil)
        try expect(await store.task(for: key1) != nil)
        try expect(await store.task(for: key2) != nil)
    }
}
