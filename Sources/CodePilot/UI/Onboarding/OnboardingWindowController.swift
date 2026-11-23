import AppKit
import CodePilotCore
import SwiftUI

struct DetectedAgentTool: Identifiable {
    let id: String
    let name: String
    let pathHint: String
    let isDetected: Bool
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var step: Int = 0
    @Published var detectedTools: [DetectedAgentTool] = []

    init() {
        scanLocalTools()
    }

    func scanLocalTools() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let specs: [(String, String, String)] = [
            ("antigravity", "Antigravity", "\(home)/.gemini/antigravity"),
            ("codex", "OpenAI Codex", "\(home)/.codex"),
            ("deepseek", "DeepSeek Harness", "\(home)/.dsh"),
            ("kimi", "Kimi Code", "\(home)/.kimi-code"),
            ("workbuddy", "WorkBuddy", "\(home)/.workbuddy"),
            ("claude", "Claude Code", "\(home)/.claude")
        ]
        detectedTools = specs.map { id, name, path in
            let exists = FileManager.default.fileExists(atPath: path)
            let shortPath = path.replacingOccurrences(of: home, with: "~")
            return DetectedAgentTool(id: id, name: name, pathHint: shortPath, isDetected: exists)
        }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel = OnboardingViewModel()
    private let coordinator: AppCoordinator
    private let onComplete: () -> Void

    init(coordinator: AppCoordinator, onComplete: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onComplete = onComplete
    }

    func show() {
        viewModel.step = 0
        viewModel.scanLocalTools()

        if let existing = window {
            existing.center()
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = OnboardingView(
            coordinator: coordinator,
            viewModel: viewModel,
            onFinish: { [weak self] in
                self?.finishAndClose()
            }
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 496, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = NSHostingView(rootView: rootView)
        win.center()

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func finishAndClose() {
        onComplete()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onComplete()
        window = nil
    }
}

private struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Top step indicator
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { idx in
                    Capsule()
                        .fill(idx <= viewModel.step ? BrandPalette.braunOrange : Color.primary.opacity(0.14))
                        .frame(width: idx == viewModel.step ? 28 : 10, height: 4.5)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.step)
                }
                Spacer()
                Button("跳过") {
                    onFinish()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)
            .padding(.top, 28)
            .padding(.bottom, 12)

            Group {
                switch viewModel.step {
                case 0: welcomeStep
                case 1: detectionStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 26)

            Divider().opacity(0.35)

            // Bottom action bar
            HStack {
                if viewModel.step > 0 {
                    Button("上一步") {
                        viewModel.step -= 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                Spacer()
                if viewModel.step < 2 {
                    Button("下一步") {
                        viewModel.step += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.braunOrange)
                    .controlSize(.regular)
                } else {
                    Button("开始使用 CodePilot") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.braunOrange)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
        }
        .frame(width: 496, height: 420)
        .background(
            ZStack {
                Rectangle().fill(.regularMaterial)
                BrandPalette.surfaceTint(for: colorScheme)
            }
        )
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            CodePilotAppMarkView(size: 68)
                .padding(.top, 4)

            VStack(spacing: 5) {
                Text("欢迎来到你的 AI 编程座舱")
                    .font(.system(size: 20, weight: .bold))
                Text("专为多 AI Agent 并行工作流打造的 macOS 原生刘海与智能防休眠中枢")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                featureRow(color: BrandPalette.signalRed, title: "物理刘海实时态势", desc: "悬停丝滑展开、事件自动弹出，一目了然「等你 / 在跑 / 完成」")
                featureRow(color: BrandPalette.runningAccent(for: colorScheme), title: "6 大 AI 工具零侵入只读", desc: "纯本地监听日志与数据库，绝不修改宿主配置，不上传任何对话")
                featureRow(color: BrandPalette.emeraldGreen, title: "Amphetamine 级自动防休眠", desc: "AI 跑长任务时自动护航防休眠，支持宽限期与低电量自动熔断")
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Step 2: Tool Detection

    private var detectionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("本机 AI 工具自动探测")
                    .font(.system(size: 18, weight: .bold))
                Text("已自动扫描本地目录。未安装的工具会静默待命，日后安装即刻生效。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(viewModel.detectedTools.enumerated()), id: \.element.id) { idx, tool in
                    HStack(spacing: 10) {
                        LEDDotView(
                            color: tool.isDetected ? BrandPalette.emeraldGreen : .gray.opacity(0.45),
                            size: 8.5,
                            breathing: false
                        )
                        Text(tool.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(tool.pathHint)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(tool.isDetected ? "已就绪" : "待命")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tool.isDetected ? BrandPalette.emeraldGreen : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(tool.isDetected ? BrandPalette.emeraldGreen.opacity(0.14) : Color.primary.opacity(0.06))
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8.5)
                    if idx < viewModel.detectedTools.count - 1 {
                        Divider().padding(.leading, 30)
                    }
                }
            }
            .background(BrandPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 1)
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 3: Permissions & Live Test

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("提醒与起飞准备")
                    .font(.system(size: 18, weight: .bold))
                Text("按需开启系统通知与开机自启，点击下方按钮立刻体验真实刘海弹出与原创音效。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("macOS 系统通知")
                            .font(.system(size: 13, weight: .medium))
                        Text("当前状态：\(coordinator.notificationAuthText)")
                            .font(.system(size: 11))
                            .foregroundStyle(coordinator.notificationAuthorized ? BrandPalette.emeraldGreen : .secondary)
                    }
                    Spacer()
                    if !coordinator.notificationAuthorized {
                        Button("去系统设置") {
                            coordinator.openSystemNotificationSettings()
                        }
                        .controlSize(.small)
                    } else {
                        LEDDotView(color: BrandPalette.emeraldGreen, size: 8.5, breathing: false)
                    }
                }
                .padding(13)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动打开 CodePilot")
                            .font(.system(size: 13, weight: .medium))
                        Text("无需每次手动启动（需拖入 /Applications）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { coordinator.launchAtLoginEnabled },
                        set: { coordinator.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(BrandPalette.braunOrange)
                    .controlSize(.small)
                    .labelsHidden()
                }
                .padding(13)
            }
            .background(BrandPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 1)
            )

            // Live Morph & Sound Test Box
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("现场试一下")
                            .font(.system(size: 13, weight: .semibold))
                        Text("立即触发刘海弹簧弹出 + 原创极简音效")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("等你 · Radar") {
                        coordinator.previewAlert(status: .waitingUser)
                    }
                    .controlSize(.small)
                    Button("完成 · Chime") {
                        coordinator.previewAlert(status: .completed)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.braunOrange)
                    .controlSize(.small)
                }
                if let fb = coordinator.lastPreviewFeedback {
                    Text(fb)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(13)
            .background(BrandPalette.braunOrange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandPalette.braunOrange.opacity(0.28), lineWidth: 1)
            )

            Spacer(minLength: 0)
        }
    }

    private func featureRow(color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LEDDotView(color: color, size: 9, breathing: false)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8.5)
        .background(BrandPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 0.8)
        )
    }
}
