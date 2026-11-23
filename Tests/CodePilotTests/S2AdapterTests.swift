import CodePilotCore
import Foundation
import SQLite3

enum S2AdapterTests {
    static func deepLinkValidatorWhitelist() async throws {
        try expect(DeepLinkValidator.validatedURL(from: "codex://threads/thr_123-abc") != nil)
        try expect(DeepLinkValidator.validatedURL(from: "claude://code/continue?session=local_abc-123") != nil)

        // Reject dangerous or malformed schemes
        try expect(DeepLinkValidator.validatedURL(from: "file:///etc/passwd") == nil)
        try expect(DeepLinkValidator.validatedURL(from: "javascript:alert(1)") == nil)
        try expect(DeepLinkValidator.validatedURL(from: "codex://threads/../evil") == nil)
        try expect(DeepLinkValidator.validatedURL(from: "codex://user@threads/123") == nil)
        try expect(DeepLinkValidator.validatedURL(from: "claude://code/continue?session=abc&extra=1") == nil)
    }

    static func kimiCodeAdapterParsing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-kimi-\(UUID().uuidString)").path
        let sdir = "\(root)/sessions/s1"
        try FileManager.default.createDirectory(atPath: sdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let idx = #"{"sessionId":"s1","sessionDir":"\#(sdir)","workDir":"/tmp/myproj"}"# + "\n"
        try Data(idx.utf8).write(to: URL(fileURLWithPath: "\(root)/session_index.jsonl"))
        let state = #"{"id":"s1","cwd":"/tmp/myproj","archived":false,"lastTurnReason":"tool_use"}"#
        try Data(state.utf8).write(to: URL(fileURLWithPath: "\(sdir)/state.json"))

        let adapter = KimiCodeAdapter(rootDirectory: root)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var events: [TaskEvent] = []
            func add(_ e: TaskEvent) { lock.lock(); events.append(e); lock.unlock() }
            func all() -> [TaskEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let box = Box()
        adapter.start { box.add($0) }
        defer { adapter.stop() }
        adapter.scanOnce(isPriming: false)

        let events = box.all()
        try expect(!events.isEmpty)
        try expect(events.last?.source == .kimiCode)
        try expect(events.last?.status == .running)
        try expect(events.last?.title == "Kimi · myproj")
    }

    static func workBuddyAdapterSQLiteQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-wb-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let dbPath = "\(root)/workbuddy.db"
        var db: OpaquePointer?
        try expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE sessions (id TEXT, cwd TEXT, title TEXT, custom_title TEXT, status TEXT, updated_at INTEGER, last_activity_at INTEGER, deleted_at INTEGER);
            CREATE TABLE session_turn_interruptions (session_id TEXT, request_id TEXT, reason_code TEXT);
            CREATE TABLE automation_runtime_state (automation_id TEXT, running INTEGER, running_conversation_id TEXT);
            INSERT INTO sessions VALUES ('wb-1', '/tmp/p1', '修复构建', NULL, 'running', \(nowMs), \(nowMs), NULL);
            INSERT INTO sessions VALUES ('wb-2', '/tmp/p2', '等待审批', NULL, 'running', \(nowMs), \(nowMs), NULL);
            INSERT INTO session_turn_interruptions VALUES ('wb-2', 'req-1', 'approval');
        """
        try expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let adapter = WorkBuddyAdapter(rootDirectory: root)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var events: [TaskEvent] = []
            func add(_ e: TaskEvent) { lock.lock(); events.append(e); lock.unlock() }
            func all() -> [TaskEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let box = Box()
        adapter.start { box.add($0) }
        defer { adapter.stop() }
        adapter.refreshOnce(isPriming: false)

        let byId = Dictionary(uniqueKeysWithValues: box.all().map { ($0.sessionId, $0) })
        try expect(byId["wb-1"]?.status == .running)
        try expect(byId["wb-2"]?.status == .waitingUser)
    }

    static func codexAdapterRolloutParsing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-cx-\(UUID().uuidString)").path
        let dayDir = "\(root)/sessions/2026/11/23"
        try FileManager.default.createDirectory(atPath: dayDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let rollout = "\(dayDir)/rollout-2026-11-23T22-00-00-thr-999.jsonl"
        let adapter = CodexAdapter(rootDirectory: root)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var events: [TaskEvent] = []
            func add(_ e: TaskEvent) { lock.lock(); events.append(e); lock.unlock() }
            func all() -> [TaskEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let box = Box()
        adapter.start { box.add($0) }
        defer { adapter.stop() }

        let lines =
            #"{"type":"session_meta","payload":{"id":"thr-999","cwd":"/tmp/cxproj","source":"cli"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"exec_approval_request"}}"# + "\n"
        try Data(lines.utf8).write(to: URL(fileURLWithPath: rollout))
        adapter.processRolloutFile(at: rollout, isPriming: false)

        let events = box.all()
        try expect(events.count == 1)
        try expect(events[0].status == .waitingUser)
        try expect(events[0].deepLinkURL == "codex://threads/thr-999")
    }

    static func claudeCodeAdapterParsing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-cl-\(UUID().uuidString)").path
        let projDir = "\(root)/demo-proj"
        try FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let file = "\(projDir)/sess-42.jsonl"
        let adapter = ClaudeCodeAdapter(projectsDirectory: root)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var events: [TaskEvent] = []
            func add(_ e: TaskEvent) { lock.lock(); events.append(e); lock.unlock() }
            func all() -> [TaskEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let box = Box()
        adapter.start { box.add($0) }
        defer { adapter.stop() }

        let lines =
            #"{"type":"user","cwd":"/tmp/demo","message":{"content":"帮我重构登录接口"}}"# + "\n" +
            #"{"type":"assistant","cwd":"/tmp/demo","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion"}]}}"# + "\n"
        try Data(lines.utf8).write(to: URL(fileURLWithPath: file))
        adapter.processSessionFile(at: file, isPriming: false)

        let events = box.all()
        try expect(events.count == 1)
        try expect(events[0].status == .waitingUser)
        try expect(events[0].title == "帮我重构登录接口")
    }

    @MainActor
    static func notchStateControllerTransitions() async throws {
        let controller = NotchStateController(
            enterDelay: .milliseconds(40),
            exitDelay: .milliseconds(60)
        )
        try expect(controller.mode == .hidden)

        // Active indicator -> collapsed
        controller.hasActiveIndicator = true
        try expect(controller.mode == .collapsed)

        // Trigger toast -> toast -> expires back to collapsed
        let now = Date()
        let task = AgentTask(
            key: TaskKey(source: .antigravity, sessionId: "s1", taskId: "main"),
            epoch: "e1", lastSeq: 1, title: "完成任务", status: .completed,
            startedAt: now, updatedAt: now, lastHeartbeatAt: now
        )
        controller.triggerToast(for: task, duration: .milliseconds(80))
        try expect(controller.mode == .toast(task))
        try await Task.sleep(for: .milliseconds(140))
        try expect(controller.mode == .collapsed)

        // Hover enter -> expanded after enterDelay; exit -> collapsed after exitDelay
        controller.pointerEntered()
        try await Task.sleep(for: .milliseconds(80))
        try expect(controller.mode == .expanded)
        controller.pointerExited()
        try await Task.sleep(for: .milliseconds(100))
        try expect(controller.mode == .collapsed)

        // Fullscreen suppresses notch immediately
        controller.isFullScreenActive = true
        try expect(controller.mode == .hidden)
        controller.isFullScreenActive = false
        try expect(controller.mode == .collapsed)
    }

    static func titleSanitizerCleaningAndFiltering() async throws {
        let cleaned = TitleSanitizer.clean("<USER_REQUEST>\n  调整刘海高度与边距  \n</USER_REQUEST>")
        try expect(cleaned == "调整刘海高度与边距")
        try expect(TitleSanitizer.clean("###  标题  ") == "标题")
        try expect(TitleSanitizer.isInternalBridgePrompt("# Applications mentioned by the user: foo") == true)
        try expect(TitleSanitizer.isInternalBridgePrompt("不要调用任何工具，请作为资深 macOS 架构师") == true)
        try expect(TitleSanitizer.isInternalBridgePrompt("帮我写一个 SwiftUI 看板") == false)
    }

    static func deepSeekBalanceAndCodexQuotaParsing() async throws {
        // 1. DeepSeek balance JSON
        let balJSON = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"42.80","granted_balance":"2.80","topped_up_balance":"40.00"}]}"#
        let bal = try DeepSeekBalanceService.parseResponse(data: Data(balJSON.utf8))
        try expect(bal.currency == "CNY")
        try expect(bal.formattedTotal == "¥42.80")
        try expect(bal.isAvailable == true)

        // 2. Codex local rollout tail rate_limits
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cp-rl-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300},"secondary":{"used_percent":6.0,"window_minutes":10080}}}}"# + "\n"
        try Data(line.utf8).write(to: URL(fileURLWithPath: tmp))

        let quota = CodexQuotaService.parseRolloutTail(at: tmp)
        try expect(quota?.primaryRemainingPercent == 88)
        try expect(quota?.secondaryRemainingPercent == 94)
    }

    static func titleSanitizerBoundsAndMetadata() async throws {
        try expect(TitleSanitizer.clean("Hello", maxLength: 0) == nil, "maxLength=0 must not crash and return nil")
        try expect(TitleSanitizer.clean("Hello", maxLength: -5) == nil, "negative maxLength must return nil")
        try expect(TitleSanitizer.clean("Hello", maxLength: 1) == "H", "maxLength=1 should return 1 char")
        let withMeta = "<USER_REQUEST>继续<ADDITIONAL_METADATA>The current local time is: 2026-11-24T01:30:17+08:00.</ADDITIONAL_METADATA>"
        try expect(TitleSanitizer.clean(withMeta) == "继续", "Metadata tail should be stripped")
    }

    static func antigravityApprovalTriggersWaitingUser() async throws {
        let bypassCall: [[String: Any]] = [[
            "name": "run_command",
            "arguments": ["CommandLine": "open dist/CodePilot.app", "BypassSandbox": true]
        ]]
        try expect(AntigravityAdapter.detectWaitingUserReason(in: bypassCall) != nil, "BypassSandbox run_command should trigger waitingUser")

        let planCall: [[String: Any]] = [[
            "name": "write_file",
            "arguments": ["ArtifactMetadata": "{\"RequestFeedback\":true,\"UserFacing\":true}"]
        ]]
        try expect(AntigravityAdapter.detectWaitingUserReason(in: planCall) != nil, "RequestFeedback artifact should trigger waitingUser")

        let normalCall: [[String: Any]] = [[
            "name": "run_command",
            "arguments": ["CommandLine": "ls -la", "BypassSandbox": false]
        ]]
        try expect(AntigravityAdapter.detectWaitingUserReason(in: normalCall) == nil, "Normal sandboxed run_command should not trigger waitingUser")
    }

    static func processRuleKeepAwakeAndLowBattery() async throws {
        let backend = MockPowerAssertionBackend()
        let manager = PowerAssertionManager(
            backend: backend,
            policy: PowerPolicy(lowBatteryThreshold: 20, lowBatteryHysteresis: 5)
        )
        await manager.syncProcessRules(matchedProcesses: ["xcodebuild"])
        let snap1 = await manager.snapshot()
        try expect(snap1.isKeepingAwake, "Matched process rule should keep awake")
        try expect(snap1.primaryReason?.contains("xcodebuild") == true, "Primary reason should include process name")

        await manager.handleBatteryUpdate(BatteryStatus(isOnBattery: true, percentage: 18))
        let snapLow = await manager.snapshot()
        try expect(!snapLow.isKeepingAwake, "Low battery should cut off processRule keep-awake")

        await manager.handleBatteryUpdate(BatteryStatus(isOnBattery: false, percentage: 26))
        let snapRecovered = await manager.snapshot()
        try expect(snapRecovered.isKeepingAwake, "Recovering battery should restore processRule keep-awake")

        await manager.syncProcessRules(matchedProcesses: [])
        let snapReleased = await manager.snapshot()
        try expect(!snapReleased.isKeepingAwake, "Clearing matched processes should release assertion")
    }
}
