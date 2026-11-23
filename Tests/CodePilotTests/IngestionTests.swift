import CodePilotCore
import Darwin
import Foundation

enum IngestionTests {
    static func eventEnvelopeValidation() async throws {
        let valid = Data(#"{"v":1,"type":"upsert","source":"antigravity","epoch":"e1","sessionId":"s1","seq":1,"status":"running","title":"测试"}"#.utf8)
        let env = try EventEnvelope.decode(lineData: valid)
        try expect(env.source == .antigravity)
        try expect(env.status == .running)
        try expect(env.toTaskEvent().taskId == "main")

        // Unsupported version
        let badVer = Data(#"{"v":2,"type":"upsert","source":"antigravity","epoch":"e1","sessionId":"s1","seq":1,"status":"running"}"#.utf8)
        do {
            _ = try EventEnvelope.decode(lineData: badVer)
            throw TestFailure.expectationFailed("Expected unsupportedVersion error", file: #file, line: #line)
        } catch let err as EventEnvelopeError {
            try expect(err == .unsupportedVersion(2))
        }

        // Missing status on upsert
        let noStatus = Data(#"{"v":1,"type":"upsert","source":"antigravity","epoch":"e1","sessionId":"s1","seq":1}"#.utf8)
        do {
            _ = try EventEnvelope.decode(lineData: noStatus)
            throw TestFailure.expectationFailed("Expected missingRequiredField", file: #file, line: #line)
        } catch let err as EventEnvelopeError {
            try expect(err == .missingRequiredField("status"))
        }

        // Oversized line
        let tooLong = Data(repeating: 0x41, count: EventEnvelope.maxLineBytes + 1)
        do {
            _ = try EventEnvelope.decode(lineData: tooLong)
            throw TestFailure.expectationFailed("Expected lineTooLong", file: #file, line: #line)
        } catch let err as EventEnvelopeError {
            try expect(err == .lineTooLong)
        }

        // Control char in sessionId
        let ctrl = Data(#"{"v":1,"type":"upsert","source":"antigravity","epoch":"e1","sessionId":"s1\tbad","seq":1,"status":"running"}"#.utf8)
        do {
            _ = try EventEnvelope.decode(lineData: ctrl)
            throw TestFailure.expectationFailed("Expected invalidField", file: #file, line: #line)
        } catch let err as EventEnvelopeError {
            try expect(err == .invalidField("sessionId_control_char"))
        }

        // Overly long sessionId
        let longId = String(repeating: "a", count: 129)
        let longIdData = Data("{\"v\":1,\"type\":\"upsert\",\"source\":\"antigravity\",\"epoch\":\"e1\",\"sessionId\":\"\(longId)\",\"seq\":1,\"status\":\"running\"}".utf8)
        do {
            _ = try EventEnvelope.decode(lineData: longIdData)
            throw TestFailure.expectationFailed("Expected invalidField", file: #file, line: #line)
        } catch let err as EventEnvelopeError {
            try expect(err == .invalidField("sessionId_too_long"))
        }
    }

    static func jsonlTailerOversizedLineDiscardsUntilNewline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-over-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("over.jsonl").path
        let tailer = JSONLTailer(maxLineBytes: 1024, initialTailWindowBytes: 4096)

        // Write an oversized incomplete line (>1024 bytes without '\n')
        try Data(repeating: 0x61, count: 1500).write(to: URL(fileURLWithPath: file))
        let batch1 = tailer.readNewLines(at: file)
        try expect(batch1.isEmpty)

        // Finish the oversized line with '\n', then append a valid line
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("tail-of-huge-line\n{\"ok\":true}\n".utf8))
        try fh.close()

        let batch2 = tailer.readNewLines(at: file)
        try expect(batch2.count == 1)
        try expect(String(data: batch2[0], encoding: .utf8) == "{\"ok\":true}")
    }

    static func jsonlTailerIncrementalAndPartialLine() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-tailer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("test.jsonl").path
        let tailer = JSONLTailer()

        // Write 1 full line + 1 partial line (no trailing newline)
        try Data("{\"step\":1}\n{\"step\":".utf8).write(to: URL(fileURLWithPath: file))
        let batch1 = tailer.readNewLines(at: file)
        try expect(batch1.count == 1)
        try expect(String(data: batch1[0], encoding: .utf8) == "{\"step\":1}")

        // Append rest of line 2 + line 3
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("2}\n{\"step\":3}\n".utf8))
        try handle.close()

        let batch2 = tailer.readNewLines(at: file)
        try expect(batch2.count == 2)
        try expect(String(data: batch2[0], encoding: .utf8) == "{\"step\":2}")
        try expect(String(data: batch2[1], encoding: .utf8) == "{\"step\":3}")
    }

    static func jsonlTailerRotationAndColdStartWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-rot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("big.jsonl").path
        // Create a file larger than initialTailWindowBytes (4096)
        var payload = Data()
        for i in 0..<200 {
            payload.append(Data("{\"i\":\(i),\"pad\":\"\(String(repeating: "x", count: 40))\"}\n".utf8))
        }
        try payload.write(to: URL(fileURLWithPath: file))

        let tailer = JSONLTailer(initialTailWindowBytes: 4096)
        let coldLines = tailer.readNewLines(at: file)
        // Must have skipped early lines (not all 200) and all returned lines must be valid JSON
        try expect(coldLines.count > 10 && coldLines.count < 200)
        for line in coldLines {
            _ = try JSONSerialization.jsonObject(with: line)
        }

        // Truncate & replace with a small file -> must reset offset and read from 0
        try Data("{\"rotated\":true}\n".utf8).write(to: URL(fileURLWithPath: file))
        let afterRotate = tailer.readNewLines(at: file)
        try expect(afterRotate.count == 1)
        try expect(String(data: afterRotate[0], encoding: .utf8) == "{\"rotated\":true}")
    }

    static func unixSocketServerEndToEndAndUnsafePathGuard() async throws {
        let dir = "/tmp/cp-sock-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // 1. Refuse to unlink an existing regular file
        let regularFile = "\(dir)/not-a-socket"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: regularFile))
        let unsafeServer = UnixSocketServer(socketPath: regularFile)
        do {
            try unsafeServer.start { _ in }
            throw TestFailure.expectationFailed("Expected unsafeExistingPath error", file: #file, line: #line)
        } catch let err as UnixSocketServerError {
            try expect(err == .unsafeExistingPath(regularFile))
        }

        // 2. Real Unix Socket E2E test with pipelined NDJSON
        let sockPath = "\(dir)/events.sock"
        let store = TaskStore()
        let server = UnixSocketServer(socketPath: sockPath)
        try server.start { event in
            _ = await store.apply(event)
        }
        defer { server.stop() }

        // Verify 0600 permissions
        var st = stat()
        try expect(lstat(sockPath, &st) == 0)
        try expect((st.st_mode & 0o777) == 0o600)

        let payload =
            #"{"v":1,"type":"upsert","source":"codex","epoch":"e1","sessionId":"s1","seq":1,"status":"running","title":"测试任务"}"# + "\n" +
            #"{"v":1,"type":"upsert","source":"codex","epoch":"e1","sessionId":"s1","seq":2,"status":"waiting_user","message":"请批准"}"# + "\n"

        let acks = try sendRawToUnixSocket(path: sockPath, payload: Data(payload.utf8))
        let ackLines = acks.split(separator: "\n")
        try expect(ackLines.count == 2)
        try expect(ackLines[0].contains("\"ok\":true"))
        try expect(ackLines[1].contains("\"ok\":true"))

        let snap = await store.snapshot()
        try expect(snap.tasks.count == 1)
        try expect(snap.waitingUserCount == 1)
        try expect(snap.tasks[0].title == "测试任务")
    }

    static func antigravityAdapterTranscriptParsing() async throws {
        let brainDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-ag-\(UUID().uuidString)").path
        let convId = "conv-123456"
        let logDir = "\(brainDir)/\(convId)/.system_generated/logs"
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: brainDir) }

        let transcriptPath = "\(logDir)/transcript.jsonl"
        let adapter = AntigravityAdapter(brainDirectory: brainDir)

        final class EventCollector: @unchecked Sendable {
            private let lock = NSLock()
            var events: [TaskEvent] = []
            func append(_ e: TaskEvent) {
                lock.lock()
                events.append(e)
                lock.unlock()
            }
            func all() -> [TaskEvent] {
                lock.lock()
                defer { lock.unlock() }
                return events
            }
        }

        let collector = EventCollector()
        adapter.start { event in
            collector.append(event)
        }
        defer { adapter.stop() }
        try expect(adapter.healthStatus == .active(watchedPath: brainDir))

        // Step 1: USER_INPUT -> running
        try Data((#"{"type":"USER_INPUT","status":"DONE","content":"帮我实现 CodePilot 的 M2 协议"}"# + "\n").utf8)
            .write(to: URL(fileURLWithPath: transcriptPath))
        adapter.processTranscriptFile(at: transcriptPath)

        // Step 2: PLANNER_RESPONSE with ask_question -> waiting_user
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: transcriptPath))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((#"{"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"ask_question"}]}"# + "\n").utf8))
        adapter.processTranscriptFile(at: transcriptPath)

        // Step 3: PLANNER_RESPONSE DONE without tool_calls -> completed
        try fh.write(contentsOf: Data((#"{"type":"PLANNER_RESPONSE","status":"DONE","content":"已完成"}"# + "\n").utf8))
        try fh.close()
        adapter.processTranscriptFile(at: transcriptPath)

        let events = collector.all()
        try expect(events.count == 3)
        try expect(events[0].status == .running)
        try expect(events[0].title == "帮我实现 CodePilot 的 M2 协议")
        try expect(events[1].status == .waitingUser)
        try expect(events[2].status == .completed)
    }

    static func deepseekHarnessAdapterProjCacheParsing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-dsh-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionFile = "\(dir)/session-abc-123.json"
        let adapter = DeepSeekHarnessAdapter(projCacheDirectory: dir)

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var events: [TaskEvent] = []
            func append(_ e: TaskEvent) { lock.lock(); events.append(e); lock.unlock() }
            func all() -> [TaskEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let collector = Collector()
        adapter.start { collector.append($0) }
        defer { adapter.stop() }
        try expect(adapter.healthStatus == .active(watchedPath: dir))

        // 1. Open turn -> running
        let runningJSON = #"{"version":7,"record":{"identity":{"cwd":"/tmp/demo"},"rows":{"title":{"ver":1,"seq":1,"val":"重构登录模块"},"turnBoundary":{"ver":1,"seq":10,"val":{"openTurnStartSeq":5,"lastStepBoundary":{"kind":"start","seq":9}}},"approvalState":{"ver":1,"seq":10,"val":{"policy":"ask","turnOpen":true}},"userQuestions":{"ver":1,"seq":10,"val":{"questions":{"active":[],"settled":[]}}}}}}"#
        try Data(runningJSON.utf8).write(to: URL(fileURLWithPath: sessionFile))
        adapter.processSessionFile(at: sessionFile, isPriming: false)

        // 2. Active userQuestion -> waiting_user (bump file size so fingerprint changes)
        let waitingJSON = #"{"version":7,"record":{"identity":{"cwd":"/tmp/demo"},"rows":{"title":{"ver":1,"seq":1,"val":"重构登录模块"},"turnBoundary":{"ver":1,"seq":15,"val":{"openTurnStartSeq":5,"lastStepBoundary":{"kind":"start","seq":14}}},"approvalState":{"ver":1,"seq":15,"val":{"policy":"ask","turnOpen":true}},"userQuestions":{"ver":1,"seq":15,"val":{"questions":{"active":[{"id":"q1","text":"确认?"}],"settled":[]}}}}}}"#
        try Data(waitingJSON.utf8).write(to: URL(fileURLWithPath: sessionFile))
        adapter.processSessionFile(at: sessionFile, isPriming: false)

        // 3. Closed turn -> completed
        let doneJSON = #"{"version":7,"record":{"identity":{"cwd":"/tmp/demo"},"rows":{"title":{"ver":1,"seq":1,"val":"重构登录模块"},"turnBoundary":{"ver":1,"seq":22,"val":{"openTurnStartSeq":null,"lastStepBoundary":{"kind":"end","seq":21}}},"approvalState":{"ver":1,"seq":22,"val":{"policy":"ask","turnOpen":false}},"userQuestions":{"ver":1,"seq":22,"val":{"questions":{"active":[],"settled":[]}}}}}}"#
        try Data(doneJSON.utf8).write(to: URL(fileURLWithPath: sessionFile))
        adapter.processSessionFile(at: sessionFile, isPriming: false)

        let events = collector.all()
        try expect(events.count == 3)
        try expect(events[0].status == .running && events[0].provenLive == true)
        try expect(events[0].title == "重构登录模块")
        try expect(events[1].status == .waitingUser)
        try expect(events[2].status == .completed)
    }

    private static func sendRawToUnixSocket(path: String, payload: Data) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TestFailure.expectationFailed("socket() failed", file: #file, line: #line)
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: utf8.count + 1) { dst in
                for i in 0..<utf8.count { dst[i] = utf8[i] }
                dst[utf8.count] = 0
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            throw TestFailure.expectationFailed("connect() failed errno=\(errno)", file: #file, line: #line)
        }

        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = Darwin.write(fd, base, payload.count)
            }
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                response.append(contentsOf: buf[0..<n])
            } else {
                break
            }
        }
        return String(data: response, encoding: .utf8) ?? ""
    }
}
