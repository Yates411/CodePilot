import CodePilotCore
import Foundation

final class MockPowerAssertionBackend: PowerAssertionBackend, @unchecked Sendable {
    enum Operation: Equatable, Sendable {
        case create(id: UInt32, level: PowerAssertionLevel)
        case release(id: UInt32)
    }

    private let lock = NSLock()
    private var nextID: UInt32 = 100
    private var _operations: [Operation] = []

    var operations: [Operation] {
        lock.lock()
        defer { lock.unlock() }
        return _operations
    }

    func createAssertion(level: PowerAssertionLevel, reason: String) -> Result<UInt32, PowerAssertionError> {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        _operations.append(.create(id: id, level: level))
        return .success(id)
    }

    func releaseAssertion(id: UInt32) -> Result<Void, PowerAssertionError> {
        lock.lock()
        defer { lock.unlock() }
        _operations.append(.release(id: id))
        return .success(())
    }
}

enum PowerAssertionManagerTests {
    static func aiAutoKeepAwakeAndGracePeriod() async throws {
        let backend = MockPowerAssertionBackend()
        let policy = PowerPolicy(gracePeriod: .milliseconds(150))
        let manager = PowerAssertionManager(backend: backend, policy: policy)

        await manager.updateRunningTaskCount(1)
        var snap = await manager.snapshot()
        try expect(snap.activeLevel == .systemOnly)
        try expect(snap.isKeepingAwake)

        await manager.updateRunningTaskCount(0)
        snap = await manager.snapshot()
        try expect(snap.isKeepingAwake)
        try expect(snap.graceDeadline != nil)

        try await Task.sleep(for: .milliseconds(280))
        snap = await manager.snapshot()
        try expect(!snap.isKeepingAwake)
        try expect(snap.activeLevel == nil)
    }

    static func newTaskCancelsGracePeriod() async throws {
        let backend = MockPowerAssertionBackend()
        let policy = PowerPolicy(gracePeriod: .milliseconds(180))
        let manager = PowerAssertionManager(backend: backend, policy: policy)

        await manager.updateRunningTaskCount(1)
        await manager.updateRunningTaskCount(0)
        try await Task.sleep(for: .milliseconds(60))
        await manager.updateRunningTaskCount(1)

        try await Task.sleep(for: .milliseconds(220))
        let snap = await manager.snapshot()
        try expect(snap.isKeepingAwake)
        try expect(snap.graceDeadline == nil)
        try expect(backend.operations == [.create(id: 100, level: .systemOnly)])
    }

    static func multipleLeasesAndMakeBeforeBreak() async throws {
        let backend = MockPowerAssertionBackend()
        let policy = PowerPolicy(gracePeriod: .zero)
        let manager = PowerAssertionManager(backend: backend, policy: policy)

        await manager.updateRunningTaskCount(1)
        await manager.acquireManualIndefinite(level: .systemAndDisplay)
        await manager.updateRunningTaskCount(0)

        let snap = await manager.snapshot()
        try expect(snap.activeLevel == .systemAndDisplay)
        try expect(backend.operations == [
            .create(id: 100, level: .systemOnly),
            .create(id: 101, level: .systemAndDisplay),
            .release(id: 100)
        ])

        await manager.releaseManualIndefinite()
        try expect(await manager.snapshot().isKeepingAwake == false)
        try expect(backend.operations.last == .release(id: 101))
    }

    static func lowBatteryCutoffAndHysteresis() async throws {
        let backend = MockPowerAssertionBackend()
        let policy = PowerPolicy(
            gracePeriod: .zero,
            lowBatteryThreshold: 20,
            lowBatteryHysteresis: 5,
            lowBatteryCancelsManual: false
        )
        let manager = PowerAssertionManager(backend: backend, policy: policy)

        await manager.updateRunningTaskCount(1)
        try expect(await manager.snapshot().isKeepingAwake)

        await manager.handleBatteryUpdate(BatteryStatus(isOnBattery: true, percentage: 20))
        var snap = await manager.snapshot()
        try expect(snap.isAutoBlockedByLowBattery)
        try expect(!snap.isKeepingAwake)

        await manager.acquireManualIndefinite(level: .systemOnly)
        try expect(await manager.snapshot().isKeepingAwake)
        await manager.releaseManualIndefinite()

        await manager.handleBatteryUpdate(BatteryStatus(isOnBattery: true, percentage: 23))
        try expect(await manager.snapshot().isAutoBlockedByLowBattery)
        try expect(await manager.snapshot().isKeepingAwake == false)

        await manager.handleBatteryUpdate(BatteryStatus(isOnBattery: false, percentage: 23))
        snap = await manager.snapshot()
        try expect(!snap.isAutoBlockedByLowBattery)
        try expect(snap.isKeepingAwake)
    }

    static func systemWakeRebuildsAssertionHandle() async throws {
        let backend = MockPowerAssertionBackend()
        let manager = PowerAssertionManager(backend: backend)

        await manager.acquireManualIndefinite(level: .systemOnly)
        await manager.handleSystemWake()

        try expect(backend.operations == [
            .create(id: 100, level: .systemOnly),
            .create(id: 101, level: .systemOnly),
            .release(id: 100)
        ])
    }

    static func policyNormalizationAndReasonTruncation() async throws {
        let weirdPolicy = PowerPolicy(
            gracePeriod: .seconds(-10),
            lowBatteryThreshold: 150,
            lowBatteryHysteresis: -20
        )
        try expect(weirdPolicy.gracePeriod == .zero)
        try expect(weirdPolicy.lowBatteryThreshold == 100)
        try expect(weirdPolicy.lowBatteryHysteresis == 0)

        let longReason = String(repeating: "A", count: 200)
        let truncated = IOKitPowerAssertionBackend.truncateReason(longReason)
        try expect(truncated.count == 128)
        try expect(truncated.hasSuffix("…"))
    }

    static func listenerReceivesOrderedVersions() async throws {
        let backend = MockPowerAssertionBackend()
        let manager = PowerAssertionManager(backend: backend, policy: PowerPolicy(gracePeriod: .zero))

        actor VersionRecorder {
            var versions: [UInt64] = []
            func append(_ v: UInt64) { versions.append(v) }
            func all() -> [UInt64] { versions }
        }

        let recorder = VersionRecorder()
        _ = await manager.addListener { snap in
            await recorder.append(snap.version)
        }

        await manager.acquireManualIndefinite(level: .systemOnly)
        await manager.acquireManualIndefinite(level: .systemAndDisplay)
        await manager.releaseManualIndefinite()

        try await Task.sleep(for: .milliseconds(80))
        let versions = await recorder.all()
        try expect(versions.count >= 3)
        try expect(versions == versions.sorted())
        try expect(Set(versions).count == versions.count)
    }
}
