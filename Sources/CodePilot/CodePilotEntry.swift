import AppKit
import CodePilotCore
import Foundation
import SwiftUI

@MainActor
final class CodePilotAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        coordinator.startIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else {
            return .terminateNow
        }
        terminationInProgress = true
        Task { @MainActor in
            await coordinator.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private enum MenuBarGlyphMode {
    case idle
    case running
    case waiting
    case keepAwakeOnly
}

private enum MenuBarIconRenderer {
    static func image(for mode: MenuBarGlyphMode) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            // 1. Warm ceramic squircle body (miniature App Icon)
            let bodyRect = NSRect(x: 1.5, y: 1.5, width: 15.0, height: 15.0)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3.8, yRadius: 3.8)
            NSColor(srgbRed: 0.96, green: 0.945, blue: 0.915, alpha: 1.0).setFill()
            bodyPath.fill()
            NSColor.black.withAlphaComponent(0.22).setStroke()
            bodyPath.lineWidth = 0.75
            bodyPath.stroke()

            // 2. Top black pill with 3 precision LEDs
            let pillRect = NSRect(x: 3.6, y: 3.6, width: 10.8, height: 4.1)
            NSColor(srgbRed: 0.08, green: 0.085, blue: 0.10, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 2.05, yRadius: 2.05).fill()

            let leds: [(CGFloat, NSColor)] = [
                (6.2, NSColor(srgbRed: 1.0, green: 0.353, blue: 0.122, alpha: 1.0)),
                (9.0, NSColor(srgbRed: 0.196, green: 0.824, blue: 1.0, alpha: 1.0)),
                (11.8, NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1.0))
            ]
            for (cx, color) in leds {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - 0.85, y: 5.65 - 0.85, width: 1.7, height: 1.7)).fill()
            }

            // 3. Bottom-left micro grille dots
            NSColor(srgbRed: 0.60, green: 0.58, blue: 0.56, alpha: 0.9).setFill()
            for r in 0..<2 {
                for c in 0..<2 {
                    let x = 4.6 + CGFloat(c) * 2.1
                    let y = 10.6 + CGFloat(r) * 2.1
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.15, height: 1.15)).fill()
                }
            }

            // 4. Bottom-right signature Braun orange action button
            NSColor(srgbRed: 1.0, green: 0.353, blue: 0.122, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: NSRect(x: 10.2, y: 9.8, width: 4.2, height: 4.2)).fill()

            // 5. Waiting / Keep-Awake status badge dot at top-right corner
            if mode == .waiting {
                NSColor(srgbRed: 1.0, green: 0.27, blue: 0.20, alpha: 1.0).setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.8, y: 0.6, width: 4.6, height: 4.6)).fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: 12.8, y: 0.6, width: 4.6, height: 4.6))
                ring.lineWidth = 0.8
                ring.stroke()
            } else if mode == .keepAwakeOnly {
                NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1.0).setFill()
                NSBezierPath(ovalIn: NSRect(x: 13.0, y: 0.8, width: 4.2, height: 4.2)).fill()
            }

            return true
        }
        img.isTemplate = false
        return img
    }
}

/// Transparent overlay inside the MenuBarExtra label that intercepts right-click
/// to show a native macOS quick-action NSMenu without interfering with left-click Popover.
private struct MenuBarRightClickOverlay: NSViewRepresentable {
    let coordinator: AppCoordinator
    let openSettingsAction: () -> Void

    func makeNSView(context: Context) -> RightClickCatcherView {
        let view = RightClickCatcherView()
        view.coordinator = coordinator
        view.openSettingsAction = openSettingsAction
        return view
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.coordinator = coordinator
        nsView.openSettingsAction = openSettingsAction
    }

    @MainActor
    final class RightClickCatcherView: NSView {
        weak var coordinator: AppCoordinator?
        var openSettingsAction: (() -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            guard let coordinator else { return }
            let menu = NSMenu(title: "CodePilot")

            let isManual = coordinator.powerSnapshot.activeLeases.contains { $0.kind == .manualIndefinite }
            let permItem = NSMenuItem(
                title: isManual ? "关闭永久防休眠" : "防休眠 · 永久开启",
                action: #selector(togglePermanent),
                keyEquivalent: ""
            )
            permItem.target = self
            menu.addItem(permItem)

            for mins in [15, 30, 60] {
                let item = NSMenuItem(
                    title: "防休眠 · 定时 \(mins) 分钟",
                    action: #selector(startTimed(_:)),
                    keyEquivalent: ""
                )
                item.tag = mins
                item.target = self
                menu.addItem(item)
            }

            if coordinator.powerSnapshot.isKeepingAwake {
                let releaseItem = NSMenuItem(title: "全部释放防休眠", action: #selector(releaseAll), keyEquivalent: "")
                releaseItem.target = self
                menu.addItem(releaseItem)
            }

            menu.addItem(.separator())

            let muteItem = NSMenuItem(
                title: coordinator.alertsPaused ? "恢复提醒与提示音" : "暂停提醒 1 小时",
                action: #selector(toggleMute),
                keyEquivalent: ""
            )
            muteItem.target = self
            menu.addItem(muteItem)

            menu.addItem(.separator())

            let settingsItem = NSMenuItem(title: "打开设置…", action: #selector(openSettingsMenu), keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(settingsItem)

            let quitItem = NSMenuItem(title: "退出 CodePilot", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func togglePermanent() {
            coordinator?.toggleManualKeepAwake()
        }

        @objc private func startTimed(_ sender: NSMenuItem) {
            coordinator?.startTimedKeepAwake(minutes: sender.tag)
        }

        @objc private func releaseAll() {
            coordinator?.releaseAllKeepAwake()
        }

        @objc private func toggleMute() {
            guard let coordinator else { return }
            if coordinator.alertsPaused {
                coordinator.resumeAlerts()
            } else {
                coordinator.pauseAlerts(minutes: 60)
            }
        }

        @objc private func openSettingsMenu() {
            NSApp.activate(ignoringOtherApps: true)
            openSettingsAction?()
        }

        @objc private func quitApp() {
            NSApp.terminate(nil)
        }
    }
}

private struct MenuBarLabelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 3.5) {
            Image(nsImage: MenuBarIconRenderer.image(for: glyphMode))
                .renderingMode(.original)
            if coordinator.waitingUserCount > 0 {
                Text("\(coordinator.waitingUserCount)")
                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
            } else if coordinator.runningCount > 0 {
                Text("\(coordinator.runningCount)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            }
        }
        .overlay(
            MenuBarRightClickOverlay(coordinator: coordinator) {
                openSettings()
            }
        )
    }

    private var glyphMode: MenuBarGlyphMode {
        if coordinator.waitingUserCount > 0 { return .waiting }
        if coordinator.runningCount > 0 { return .running }
        if coordinator.powerSnapshot.isKeepingAwake { return .keepAwakeOnly }
        return .idle
    }
}

struct CodePilotMenuBarApp: App {
    @NSApplicationDelegateAdaptor(CodePilotAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(coordinator: appDelegate.coordinator)
        } label: {
            MenuBarLabelView(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
    }
}

@main
struct CodePilotEntry {
    static func main() {
        let args = CommandLine.arguments

        if args.count >= 2 && args[1] == "emit" {
            let code = runEmitCLI(args: Array(args.dropFirst(2)))
            exit(code)
        }

        if args.contains("--smoke-power") {
            let group = DispatchGroup()
            group.enter()
            Task {
                await runSmokePower()
                group.leave()
            }
            group.wait()
            return
        }

        if args.contains("--listen") {
            let socketPath: String
            if let idx = args.firstIndex(of: "--socket"), idx + 1 < args.count {
                socketPath = args[idx + 1]
            } else {
                socketPath = UnixSocketServer.defaultSocketPath
            }
            let group = DispatchGroup()
            group.enter()
            Task {
                await runHeadlessListen(socketPath: socketPath)
                group.leave()
            }
            group.wait()
            return
        }

        CodePilotMenuBarApp.main()
    }

    /// Minimal CLI subcommand for community hooks (Cursor / Windsurf / Shell):
    /// `CodePilot emit --source custom --status waiting_user --title "Build finished" --message "Review required"`
    private static func runEmitCLI(args: [String]) -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            print("""
            Usage: CodePilot emit [options]
              --source <antigravity|codex|claude_code|deepseek_harness|kimi_code|workbuddy|custom>
              --status <running|waiting_user|completed|error|remove>
              --title <string>
              --message <string>
              --session <string>
              --task <string>
              --socket <path>
            """)
            return 0
        }

        func option(_ flag: String, default fallback: String? = nil) -> String? {
            if let idx = args.firstIndex(of: flag), idx + 1 < args.count {
                return args[idx + 1]
            }
            return fallback
        }

        let source = option("--source", default: "custom") ?? "custom"
        let status = option("--status", default: "completed") ?? "completed"
        let session = option("--session", default: "cli-\(ProcessInfo.processInfo.processIdentifier)") ?? "cli"
        let taskId = option("--task", default: "main") ?? "main"
        let title = option("--title", default: "CLI Task") ?? "CLI Task"
        let message = option("--message")
        let socketPath = option("--socket", default: UnixSocketServer.defaultSocketPath) ?? UnixSocketServer.defaultSocketPath

        let nowSeq = UInt64(Date().timeIntervalSince1970 * 1000)
        var payloadObj: [String: Any] = [
            "v": 1,
            "type": status == "remove" ? "remove" : "upsert",
            "source": source,
            "epoch": "cli",
            "session_id": session,
            "task_id": taskId,
            "seq": nowSeq,
            "title": title,
            "pid": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        if status != "remove" {
            payloadObj["status"] = status
        }
        if let message, !message.isEmpty {
            payloadObj["message"] = message
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payloadObj, options: [])
            let reply = try UnixSocketClient.send(payload: data, socketPath: socketPath)
            print(reply)
            return 0
        } catch {
            fputs("[CodePilot emit] \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runSmokePower() async {
        let manager = PowerAssertionManager()
        await manager.acquireManualIndefinite(level: .systemOnly, reason: "M1 Smoke Test")
        let snap = await manager.snapshot()
        print("CodePilot smoke-power active=\(snap.isKeepingAwake) level=\(String(describing: snap.activeLevel))")
        if let battery = BatteryMonitor.currentStatus() {
            print("Battery: onBattery=\(battery.isOnBattery) percentage=\(battery.percentage)%")
        }
        try? await Task.sleep(for: .seconds(3))
        await manager.releaseAll()
        let released = await manager.snapshot()
        print("CodePilot smoke-power released active=\(released.isKeepingAwake)")
    }

    private static func runHeadlessListen(socketPath: String) async {
        let store = TaskStore()
        let power = PowerAssertionManager(policy: PowerPolicy(gracePeriod: .seconds(5)))
        _ = await store.addListener { snap in
            await power.updateRunningTaskCount(snap.runningCount)
            let powerSnap = await power.snapshot()
            print("[CodePilot] tasks=\(snap.tasks.count) running=\(snap.runningCount) waiting=\(snap.waitingUserCount) keepAwake=\(powerSnap.isKeepingAwake)")
            fflush(stdout)
        }
        let server = UnixSocketServer(socketPath: socketPath)
        do {
            try server.start { event in
                _ = await store.apply(event)
            }
            print("[CodePilot] listening on \(socketPath)")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(3600))
        } catch {
            fputs("[CodePilot] failed to start socket server: \(error)\n", stderr)
            exit(1)
        }
    }
}
