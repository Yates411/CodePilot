# Contributing to CodePilot

Thank you for your interest in contributing to **CodePilot**!

## Core Engineering Principles

1. **100% Local Read-Only, Zero Intrusion**: Never modify host AI tool configs, databases, or binaries. All adapters must strictly read local session files/SQLite in read-only mode.
2. **Pure Native Swift 6**: Zero Electron, zero Node.js runtime, zero third-party runtime dependencies. Keep the release `.app` lightweight (~4–5 MB).
3. **Strict Concurrency & No SwiftUI Macro Lock-in**: Code compiles cleanly with `swiftc -swift-version 6` using macOS CommandLineTools alone (avoid `@State` / `@Observable` macros so CLT-only contributors can build without full Xcode).

---

## Local Build & Test

```bash
# Build debug binary
./scripts/build.sh debug

# Run all unit tests
./scripts/test.sh

# Build & ad-hoc sign Release .app bundle
./scripts/bundle_app.sh release
```

---

## 80-Line Guide: Add a New AI Coding Agent Adapter

CodePilot's ingestion layer is designed so any developer can add a new AI coding agent adapter in ~80 lines of Swift:

1. **Add a case to `AgentSource`** in `Sources/CodePilotCore/Core/Models/TaskModels.swift` (e.g. `case cursor = "cursor"`), plus its `displayName` and 3-letter `oledCode` in `DesignTokens.swift`.
2. **Create `Sources/CodePilotCore/Ingestion/Adapters/YourToolAdapter.swift`** conforming to `AgentAdapter`:

```swift
import Foundation

public final class YourToolAdapter: AgentAdapter, @unchecked Sendable {
    public let source: AgentSource = .custom
    public private(set) var healthStatus: AdapterHealth = .idle
    private let watcher = FSEventWatcher(label: "com.codepilot.adapter.yourtool")
    private let tailer = JSONLTailer()
    private let epoch = "yt-\(UUID().uuidString.prefix(8))"
    private var seq: UInt64 = 0

    public func start(emit: @escaping @Sendable (TaskEvent) -> Void) {
        let dir = "\(NSHomeDirectory())/.your-tool/sessions"
        guard FileManager.default.fileExists(atPath: dir) else {
            healthStatus = .notInstalled
            return
        }
        healthStatus = .active(watchedPath: dir)
        _ = watcher.start(paths: [dir], latency: 0.3) { [weak self] paths in
            guard let self else { return }
            for path in paths where path.hasSuffix(".jsonl") {
                for line in self.tailer.readNewLines(at: path) {
                    // Parse status -> .running / .waitingUser / .completed / .error
                    self.seq &+= 1
                    emit(TaskEvent(
                        type: .upsert,
                        source: self.source,
                        epoch: self.epoch,
                        sessionId: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                        taskId: "main",
                        seq: self.seq,
                        status: .running,
                        title: TitleSanitizer.clean("Your Task") ?? "Task",
                        isPriming: false,
                        provenLive: true
                    ))
                }
            }
        }
    }

    public func stop() {
        watcher.stop()
        tailer.resetAll()
        healthStatus = .idle
    }
}
```

3. **Register it** in `AppCoordinator.swift`, add a toggle in `SettingsModels.swift` & `SettingsView.swift`, and add a unit test in `Tests/CodePilotTests/S2AdapterTests.swift`.
4. **Alternative (Zero Swift Code)**: Use `CodePilot emit --source custom --status waiting_user --title "..."` directly from any Shell / IDE Hook!
