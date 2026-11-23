import AppKit
import CodePilotCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(BrandPalette.cardBorder(for: colorScheme))
                .frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle()
                    .fill(BrandPalette.cardBorder(for: colorScheme))
                    .frame(height: 1)
                bottomBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 740, height: 556)
        .background(BrandPalette.chassisGradient(for: colorScheme))
        .onAppear {
            coordinator.refreshNotificationAuth()
            coordinator.refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - Sidebar (Hardware Tactile Navigation)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                CodePilotAppMarkView(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CODEPILOT")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                    Text("v\(coordinator.currentAppVersion)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(SettingsSection.allCases) { section in
                let active = coordinator.selectedSettingsSection == section
                Button {
                    coordinator.selectedSettingsSection = section
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: section.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(active ? BrandPalette.braunOrange : .secondary)
                            .frame(width: 18)
                        Text(sectionTitle(section))
                            .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? .white : .primary.opacity(0.85))
                        Spacer()
                        if active {
                            Circle()
                                .fill(BrandPalette.braunOrange)
                                .frame(width: 5.5, height: 5.5)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8.5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(active ? Color(red: 0.08, green: 0.085, blue: 0.10) : BrandPalette.cardFill(for: colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(active ? Color.white.opacity(0.12) : BrandPalette.cardBorder(for: colorScheme), lineWidth: 0.8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                BraunSpeakerGrilleView(columns: 6, rows: 2, dotSize: 3.2, spacing: 5)
                Text("100% 本地只读\n零配置修改")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
        .frame(width: 192)
        .background(colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.025))
    }

    private func sectionTitle(_ section: SettingsSection) -> String {
        switch section {
        case .connections: return "连接与工具"
        case .power: return "防休眠策略"
        case .notch: return "刘海交互"
        case .alerts: return "提醒与音效"
        case .general: return "通用设置"
        }
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailContent: some View {
        switch coordinator.selectedSettingsSection {
        case .connections:
            connectionsPage
        case .power:
            powerPage
        case .notch:
            notchPage
        case .alerts:
            alertsPage
        case .general:
            generalPage
        }
    }

    // MARK: 1. Connections Page

    private var enabledAdapterCount: Int {
        [
            coordinator.settings.antigravityEnabled,
            coordinator.settings.deepseekHarnessEnabled,
            coordinator.settings.kimiCodeEnabled,
            coordinator.settings.workbuddyEnabled,
            coordinator.settings.codexEnabled,
            coordinator.settings.claudeCodeEnabled
        ].filter { $0 }.count
    }

    private var connectionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(
                title: "连接与工具",
                subtitle: "只读监听本机 AI 编程工具会话日志，不修改任何外部配置。"
            )

            oledStatusBar(
                left: "已启用 \(enabledAdapterCount) / 6",
                right: "本地只读监听中",
                rightColor: BrandPalette.emeraldGreen
            )

            VStack(spacing: 0) {
                toolRow(name: "Antigravity", pathHint: "~/.gemini/antigravity/brain", source: .antigravity, keyPath: \.antigravityEnabled)
                hairlineDivider
                toolRow(name: "OpenAI Codex", pathHint: "~/.codex/sessions", source: .codex, keyPath: \.codexEnabled)
                hairlineDivider
                toolRow(name: "DeepSeek Harness", pathHint: "~/.dsh/storages", source: .deepseekHarness, keyPath: \.deepseekHarnessEnabled)
                hairlineDivider
                toolRow(name: "Claude Code", pathHint: "~/.claude/projects", source: .claudeCode, keyPath: \.claudeCodeEnabled)
                hairlineDivider
                toolRow(name: "Kimi Code", pathHint: "~/.kimi-code", source: .kimiCode, keyPath: \.kimiCodeEnabled)
                hairlineDivider
                toolRow(name: "WorkBuddy", pathHint: "~/.workbuddy/workbuddy.db", source: .workbuddy, keyPath: \.workbuddyEnabled)
            }
            .background(BrandPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 1)
            )

            settingsCard(title: "DeepSeek 余额与 Codex 本地额度") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示 DeepSeek 余额")
                            .font(.system(size: 13, weight: .medium))
                        Text("API Key 仅存 macOS 钥匙串，每 10 分钟查询一次")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let bal = coordinator.deepseekBalance {
                        Text(bal.formattedTotal)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(BrandPalette.emeraldGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(BrandPalette.emeraldGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Toggle("", isOn: binding(\.showDeepSeekBalance))
                        .toggleStyle(.switch)
                        .tint(BrandPalette.braunOrange)
                        .controlSize(.small)
                        .labelsHidden()
                }

                HStack(spacing: 8) {
                    SecureField("粘贴 sk- 开头的 DeepSeek API Key", text: $coordinator.deepseekKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        coordinator.saveDeepSeekAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.braunOrange)
                    .controlSize(.small)
                    if coordinator.hasDeepSeekKey {
                        Button("删除") {
                            coordinator.deleteDeepSeekAPIKey()
                        }
                        .controlSize(.small)
                    }
                }

                if let err = coordinator.deepseekBalanceError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(BrandPalette.signalRed)
                }

                hairlineDivider
                settingToggleRow(
                    title: "显示 Codex 本地剩余额度",
                    subtitle: "纯本地解析 rollout 末尾 5 小时 / 每周额度，零联网",
                    isOn: binding(\.showCodexQuota)
                )
                hairlineDivider
                settingToggleRow(
                    title: "低余额 / 低额度主动预警",
                    subtitle: "DeepSeek 低于 ¥\(Int(coordinator.settings.deepseekLowBalanceThreshold)) 或 Codex 低于 \(coordinator.settings.codexLowQuotaThreshold)% 时主动提醒",
                    isOn: binding(\.lowBalanceAlertEnabled)
                )
            }

            settingsCard(title: "本地事件通道 & CLI Hook") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.socketStatusText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("可通过 `CodePilot emit` 子命令接入 Cursor / Windsurf / Shell Hook")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("复制 Hook 命令") {
                        coordinator.copyEmitHookCommand()
                    }
                    .controlSize(.small)
                }
                if let fb = coordinator.copiedHookFeedback {
                    Text(fb)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BrandPalette.emeraldGreen)
                }
            }
        }
    }

    private func toolRow(
        name: String,
        pathHint: String,
        source: AgentSource,
        keyPath: WritableKeyPath<AppSettings, Bool>
    ) -> some View {
        let health = coordinator.health(for: source)
        let isReady: Bool = {
            if case .active = health { return true }
            return false
        }()

        return HStack(spacing: 12) {
            Circle()
                .fill(isReady ? BrandPalette.emeraldGreen : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text(pathHint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(isReady ? "已就绪" : "待命")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isReady ? BrandPalette.emeraldGreen : .secondary)

            Toggle("", isOn: binding(keyPath))
                .toggleStyle(.switch)
                .tint(BrandPalette.braunOrange)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: 2. Power Page

    private var powerPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(
                title: "防休眠策略",
                subtitle: "AI 运行长任务时自动通过 macOS IOKit 护航防休眠，任务结束后按宽限期自动释放。"
            )

            oledStatusBar(
                left: coordinator.powerSnapshot.isKeepingAwake ? "当前状态 · 防休眠激活" : "当前状态 · 正常节能",
                right: "宽限期 \(coordinator.settings.gracePeriodSeconds)s",
                rightColor: coordinator.powerSnapshot.isKeepingAwake ? BrandPalette.emeraldGreen : .white.opacity(0.6)
            )

            settingsCard(title: "AI 任务自动联动") {
                settingToggleRow(
                    title: "AI 运行时自动防休眠",
                    subtitle: "检测到任意工具存在活跃任务时自动开启",
                    isOn: binding(\.autoKeepAwakeEnabled)
                )
                hairlineDivider
                settingToggleRow(
                    title: "同时阻止显示器熄屏",
                    subtitle: "关闭时仅防系统休眠、允许屏幕熄灭省电（推荐关闭）",
                    isOn: binding(\.autoPreventDisplaySleep)
                )
                .disabled(!coordinator.settings.autoKeepAwakeEnabled)
                hairlineDivider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("任务结束后宽限期")
                            .font(.system(size: 13, weight: .medium))
                        Text("避免多轮任务间隙反复休眠")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(
                        "\(coordinator.settings.gracePeriodSeconds) 秒",
                        value: binding(\.gracePeriodSeconds),
                        in: 0...1800,
                        step: 30
                    )
                    .fixedSize()
                }
            }

            settingsCard(title: "进程触发防休眠（替代 Amphetamine）") {
                settingToggleRow(
                    title: "检测到指定进程运行时自动防休眠",
                    subtitle: "每 5 秒轻量扫描本机进程，支持编译、训练、转码等长任务",
                    isOn: binding(\.processRulesEnabled)
                )
                if coordinator.settings.processRulesEnabled {
                    hairlineDivider
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(coordinator.settings.watchedProcessNames, id: \.self) { proc in
                                let isHit = coordinator.matchedProcessRules.contains { $0.caseInsensitiveCompare(proc) == .orderedSame }
                                HStack(spacing: 4) {
                                    if isHit {
                                        Circle()
                                            .fill(BrandPalette.emeraldGreen)
                                            .frame(width: 5.5, height: 5.5)
                                    }
                                    Text(proc)
                                        .font(.system(size: 11, design: .monospaced))
                                    Button {
                                        coordinator.removeWatchedProcess(proc)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8.5, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(isHit ? BrandPalette.emeraldGreen.opacity(0.15) : Color.primary.opacity(0.06))
                                )
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("添加进程名（如 python3 / node / HandBrakeCLI）", text: $coordinator.processRuleInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    coordinator.addWatchedProcess()
                                }
                            Button("添加") {
                                coordinator.addWatchedProcess()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(BrandPalette.braunOrange)
                            .controlSize(.small)
                        }
                    }
                }
            }

            settingsCard(title: "电池低电量保护") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("低电量自动熔断阈值")
                            .font(.system(size: 13, weight: .medium))
                        Text("仅使用电池低于阈值时暂停自动防休眠（+5% 迟滞恢复）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(
                        "\(coordinator.settings.lowBatteryThreshold)%",
                        value: binding(\.lowBatteryThreshold),
                        in: 5...50,
                        step: 5
                    )
                    .fixedSize()
                }
                hairlineDivider
                settingToggleRow(
                    title: "低电量时同时取消「永久」防休眠",
                    subtitle: "默认关闭：仅熔断自动保活，不打断手动开启的永久防休眠",
                    isOn: binding(\.lowBatteryCancelsManual)
                )
            }
        }
    }

    // MARK: 3. Notch Page

    private var notchPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(
                title: "刘海交互",
                subtitle: "贴合 MacBook 物理刘海实时展示态势，悬停丝滑弹簧展开。"
            )

            oledStatusBar(
                left: coordinator.settings.notchEnabled ? "刘海交互 · 已开启" : "刘海交互 · 已关闭",
                right: "停留 \(coordinator.settings.notchToastDurationSeconds) 秒",
                rightColor: coordinator.settings.notchEnabled ? BrandPalette.telemetryCyan : .white.opacity(0.45)
            )

            previewBar

            settingsCard(title: "显示与全屏避让") {
                settingToggleRow(
                    title: "启用顶栏刘海提示",
                    subtitle: "关闭后仅保留状态栏图标",
                    isOn: binding(\.notchEnabled)
                )
                hairlineDivider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全屏 App 中")
                            .font(.system(size: 13, weight: .medium))
                        Text("看视频、共享屏幕或全屏编辑时")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: binding(\.notchFullScreenBehavior)) {
                        ForEach(FullScreenNotchBehavior.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                    .disabled(!coordinator.settings.notchEnabled)
                }
            }

            settingsCard(title: "事件自动弹出") {
                settingToggleRow(
                    title: "等你确认时自动弹出",
                    subtitle: "需要批准命令或做出决定时自动向下展开",
                    isOn: binding(\.notchAutoPopupOnWaiting)
                )
                .disabled(!coordinator.settings.notchEnabled)
                hairlineDivider
                settingToggleRow(
                    title: "任务完成时自动弹出",
                    subtitle: "一轮任务结束时平滑展开卡片",
                    isOn: binding(\.notchAutoPopupOnComplete)
                )
                .disabled(!coordinator.settings.notchEnabled)
                hairlineDivider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动弹出停留时长")
                            .font(.system(size: 13, weight: .medium))
                        Text("鼠标悬停在卡片上时不会自动收起")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: binding(\.notchToastDurationSeconds)) {
                        Text("3 秒").tag(3)
                        Text("6 秒").tag(6)
                        Text("10 秒").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(!coordinator.settings.notchEnabled)
                }
            }
        }
    }

    // MARK: 4. Alerts Page

    private var alertsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(
                title: "提醒与音效",
                subtitle: "内置原创极简 UI 音效与 macOS 系统通知，切屏工作时不错过关键节点。"
            )

            oledStatusBar(
                left: "系统通知 · \(coordinator.notificationAuthText)",
                right: coordinator.settings.soundEnabled ? "音量 \(Int((coordinator.settings.soundVolume * 100).rounded()))%" : "提示音已关",
                rightColor: coordinator.notificationAuthorized ? BrandPalette.emeraldGreen : BrandPalette.amberOrange
            )

            previewBar

            settingsCard(title: "原创提示音") {
                settingToggleRow(
                    title: "启用提示音",
                    subtitle: "按事件状态播放不同音效",
                    isOn: binding(\.soundEnabled)
                )
                if coordinator.settings.soundEnabled {
                    hairlineDivider
                    soundPickerRow(label: "等你确认", selection: binding(\.waitingSoundName))
                    hairlineDivider
                    soundPickerRow(label: "任务完成", selection: binding(\.completedSoundName))
                    hairlineDivider
                    soundPickerRow(label: "执行异常", selection: binding(\.errorSoundName))
                    hairlineDivider
                    HStack {
                        Text("音量")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Slider(value: binding(\.soundVolume), in: 0...1)
                            .tint(BrandPalette.braunOrange)
                            .frame(width: 170)
                        Text("\(Int((coordinator.settings.soundVolume * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            settingsCard(title: "macOS 系统通知") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("通知权限")
                            .font(.system(size: 13, weight: .medium))
                        Text("当前状态：\(coordinator.notificationAuthText)")
                            .font(.system(size: 11))
                            .foregroundStyle(coordinator.notificationAuthorized ? BrandPalette.emeraldGreen : BrandPalette.amberOrange)
                    }
                    Spacer()
                    if !coordinator.notificationAuthorized {
                        Button("去系统设置") {
                            coordinator.openSystemNotificationSettings()
                        }
                        .controlSize(.small)
                    }
                }
                hairlineDivider
                settingToggleRow(title: "启用系统通知", subtitle: "总开关", isOn: binding(\.notificationsEnabled))
                hairlineDivider
                settingToggleRow(title: "等你时通知", subtitle: "需审批或回答问题", isOn: binding(\.notifyOnWaiting))
                    .disabled(!coordinator.settings.notificationsEnabled)
                hairlineDivider
                settingToggleRow(title: "完成时通知", subtitle: "一轮任务结束", isOn: binding(\.notifyOnCompleted))
                    .disabled(!coordinator.settings.notificationsEnabled)
                hairlineDivider
                settingToggleRow(title: "通知内显示任务标题", subtitle: "关闭后锁屏更隐私", isOn: binding(\.showTitleInNotification))
                    .disabled(!coordinator.settings.notificationsEnabled)
            }

            settingsCard(title: "超时温和二次提醒") {
                settingToggleRow(
                    title: "「等你确认」超时再次提醒",
                    subtitle: "切入对应工具后自动停止",
                    isOn: binding(\.repeatReminderEnabled)
                )
                if coordinator.settings.repeatReminderEnabled {
                    hairlineDivider
                    HStack {
                        Text("间隔与上限")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Stepper(
                            "\(coordinator.settings.repeatReminderIntervalSeconds / 60) 分钟",
                            value: Binding(
                                get: { max(1, coordinator.settings.repeatReminderIntervalSeconds / 60) },
                                set: { mins in
                                    var copy = coordinator.settings
                                    copy.repeatReminderIntervalSeconds = mins * 60
                                    coordinator.updateSettings(copy)
                                }
                            ),
                            in: 1...30
                        )
                        Stepper(
                            "最多 \(coordinator.settings.maxRepeatReminders) 次",
                            value: binding(\.maxRepeatReminders),
                            in: 1...5
                        )
                    }
                }
            }
        }
    }

    // MARK: 5. General Page

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader(
                title: "通用设置",
                subtitle: "开机自启、欢迎引导与应用信息。"
            )

            oledStatusBar(
                left: "CodePilot v\(coordinator.currentAppVersion)",
                right: coordinator.launchAtLoginEnabled ? "开机自启 · ON" : "开机自启 · OFF",
                rightColor: coordinator.launchAtLoginEnabled ? BrandPalette.emeraldGreen : .white.opacity(0.5)
            )

            settingsCard(title: "启动与引导") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动打开 CodePilot")
                            .font(.system(size: 13, weight: .medium))
                        Text("当前状态：\(coordinator.launchAtLoginStatus)（需安装在 /Applications）")
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
                hairlineDivider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("首次启动 3 步引导")
                            .font(.system(size: 13, weight: .medium))
                        Text("重新检测本机 AI 工具并体验刘海弹出与原创音效")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新打开") {
                        coordinator.presentOnboarding()
                    }
                    .controlSize(.small)
                }
            }

            settingsCard(title: "软件更新（GitHub Releases）") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        TextField("Yates411/CodePilot", text: binding(\.githubUpdateRepo))
                            .textFieldStyle(.roundedBorder)
                        Button(coordinator.isCheckingUpdate ? "检查中…" : "检查更新") {
                            coordinator.checkForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BrandPalette.braunOrange)
                        .controlSize(.small)
                        .disabled(coordinator.isCheckingUpdate || coordinator.isInstallingUpdate)
                    }

                    if let status = coordinator.updateStatusText {
                        Text(status)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(coordinator.availableRelease != nil ? BrandPalette.braunOrange : .secondary)
                    }

                    if let release = coordinator.availableRelease {
                        HStack(spacing: 8) {
                            if release.zipAssetURL != nil {
                                Button(coordinator.isInstallingUpdate ? "下载安装中…" : "下载并更新至 \(release.tagName)") {
                                    coordinator.installAvailableUpdate()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(BrandPalette.emeraldGreen)
                                .controlSize(.small)
                                .disabled(coordinator.isInstallingUpdate)
                            }
                            Button("前往 Release 页面") {
                                coordinator.openReleasePage()
                            }
                            .controlSize(.small)
                        }
                    }

                    Text("检查 GitHub Releases 最新版本；自动校验 SHA256SUMS 后原地替换并重启。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            settingsCard(title: "关于 CodePilot") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CodePilot v\(coordinator.currentAppVersion)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("纯原生 Swift / SwiftUI / AppKit / IOKit 构建，100% 本地只读运行，零对话内容上传。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Shared Precision Components

    private func oledStatusBar(left: String, right: String, rightColor: Color) -> some View {
        HStack {
            Text(left)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Circle()
                    .fill(rightColor)
                    .frame(width: 5.5, height: 5.5)
                Text(right)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(rightColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9.5)
        .background(BrandPalette.oledBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.18), lineWidth: 1)
        )
    }

    private var previewBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("现场试一下")
                        .font(.system(size: 13, weight: .semibold))
                    Text("完整触发一次刘海弹出、原创音效与系统通知")
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

            if let feedback = coordinator.lastPreviewFeedback {
                Text(feedback)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(BrandPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 1)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("开机自动启动")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(coordinator.launchAtLoginEnabled ? "已开启" : "未开启")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(coordinator.launchAtLoginEnabled ? BrandPalette.emeraldGreen : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(coordinator.launchAtLoginEnabled ? BrandPalette.emeraldGreen.opacity(0.14) : Color.primary.opacity(0.06))
                )

            Spacer()

            Button("完成设置") {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandPalette.braunOrange)
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(BrandPalette.cardBorder(for: colorScheme))
            .frame(height: 0.75)
    }

    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 11) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandPalette.cardFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 1)
            )
        }
    }

    private func settingToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(BrandPalette.braunOrange)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private func soundPickerRow(label: String, selection: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Picker("", selection: selection) {
                Section("CodePilot 原创") {
                    ForEach(AppSettings.customSounds, id: \.self) { name in
                        Text(customSoundDisplayName(name)).tag(name)
                    }
                }
                Section("macOS 系统音") {
                    ForEach(AppSettings.systemSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 162)
            Button("试听") {
                coordinator.previewSound(named: selection.wrappedValue)
            }
            .controlSize(.small)
        }
    }

    private func customSoundDisplayName(_ name: String) -> String {
        switch name {
        case "Radar": return "Radar（声呐轻点）"
        case "Chime": return "Chime（极短三连）"
        case "Thud": return "Thud（低频双响）"
        case "Pulse": return "Pulse（马林巴五度）"
        default: return name
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] },
            set: { newValue in
                var copy = coordinator.settings
                copy[keyPath: keyPath] = newValue
                coordinator.updateSettings(copy)
            }
        )
    }
}
