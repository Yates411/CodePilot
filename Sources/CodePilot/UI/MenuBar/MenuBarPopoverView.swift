import AppKit
import CodePilotCore
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    private var waitingTasks: [AgentTask] {
        coordinator.tasks.filter { $0.status == .waitingUser }
    }

    private var runningTasks: [AgentTask] {
        coordinator.tasks.filter { $0.status == .running }
    }

    private var finishedTasks: [AgentTask] {
        coordinator.tasks.filter { $0.status.isFinished }
    }

    private var isManualActive: Bool {
        coordinator.powerSnapshot.activeLeases.contains { $0.kind == .manualIndefinite }
    }

    private var activeTimedMinutes: Int? {
        for lease in coordinator.powerSnapshot.activeLeases {
            if case .manualTimed = lease.kind {
                if lease.reason.contains("15") { return 15 }
                if lease.reason.contains("30") { return 30 }
                if lease.reason.contains("60") { return 60 }
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            chassisHeader
            oledScreen
            powerKeypadSection
            bottomMicroKeys
        }
        .padding(14)
        .frame(width: 380)
        .background(BrandPalette.chassisGradient(for: colorScheme))
    }

    // MARK: - 1. Hardware Chassis Nameplate & Speaker Grille

    private var chassisHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("CODEPILOT")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.primary)
                Text("CP-04")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.75))
            }

            Spacer()

            BraunSpeakerGrilleView(columns: 4, rows: 2, dotSize: 3.2, spacing: 3.5)

            if let battery = coordinator.batteryStatus {
                Text("\(battery.percentage)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(
                        battery.isOnBattery && battery.percentage <= coordinator.settings.lowBatteryThreshold
                            ? BrandPalette.braunOrange
                            : .secondary
                    )
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 3)
    }

    // MARK: - 2. Embedded Pure-Black OLED Screen

    private var oledScreen: some View {
        VStack(spacing: 11) {
            // 4-slot Precision Vector Icon Filter Bar
            HStack(spacing: 6) {
                oledFilterButton(tab: .all, count: coordinator.tasks.count, accent: .white) { active in
                    AllGridGlyphView(size: 11.5, color: active ? .black : .white.opacity(0.75))
                }
                oledFilterButton(tab: .waiting, count: waitingTasks.count, accent: BrandPalette.braunOrange) { active in
                    WaitingRingGlyph(size: 12.5, color: active ? .black : BrandPalette.braunOrange)
                }
                oledFilterButton(tab: .running, count: runningTasks.count, accent: BrandPalette.telemetryCyan) { active in
                    RunningOrbitGlyph(
                        size: 12.5,
                        color: active ? .black : BrandPalette.telemetryCyan,
                        animate: !runningTasks.isEmpty
                    )
                }
                oledFilterButton(tab: .finished, count: finishedTasks.count, accent: BrandPalette.emeraldGreen) { active in
                    CompletedCheckGlyph(size: 12.5, color: active ? .black : BrandPalette.emeraldGreen)
                }
            }
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.10)).frame(height: 0.75)
            }

            // Grouped Task Stream
            oledTaskList

            // OLED Bottom Telemetry & Quota Strip
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    PowerArcGlyphView(
                        size: 11,
                        color: coordinator.powerSnapshot.isKeepingAwake ? BrandPalette.emeraldGreen : .white.opacity(0.42)
                    )
                    Text(oledPowerText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(coordinator.powerSnapshot.isKeepingAwake ? BrandPalette.emeraldGreen : .white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let quotaSummary = compactQuotaText {
                    Text(quotaSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .padding(.top, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.09)).frame(height: 0.75)
            }
        }
        .padding(13)
        .background(BrandPalette.oledBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.18), lineWidth: 1)
        )
    }

    private func oledFilterButton<Icon: View>(
        tab: TaskFilterTab,
        count: Int,
        accent: Color,
        @ViewBuilder icon: (Bool) -> Icon
    ) -> some View {
        let isSelected = (coordinator.selectedFilter == tab)
        return Button {
            coordinator.selectedFilter = (isSelected && tab != .all) ? .all : tab
        } label: {
            HStack(spacing: 5) {
                icon(isSelected)
                Text("\(count)")
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? .black : (count > 0 ? accent : .white.opacity(0.42)))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white : Color.white.opacity(0.065))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var oledTaskList: some View {
        let visibleWaiting = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .waiting) ? waitingTasks : []
        let visibleRunning = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .running) ? runningTasks : []
        let visibleFinished = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .finished) ? finishedTasks : []
        let hasAny = !visibleWaiting.isEmpty || !visibleRunning.isEmpty || !visibleFinished.isEmpty

        if !hasAny {
            VStack(spacing: 5) {
                Text(coordinator.selectedFilter == .all ? "STANDBY · 待命中" : "该分类下暂无任务")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.60))
                Text("已静默监听 6 大 AI 编程工具")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.36))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
        } else {
            let groupCount = (visibleWaiting.isEmpty ? 0 : 1) + (visibleRunning.isEmpty ? 0 : 1) + (visibleFinished.isEmpty ? 0 : 1)
            let rowCount = visibleWaiting.count + visibleRunning.count + visibleFinished.count
            let desiredHeight = CGFloat(groupCount) * 24 + CGFloat(rowCount) * 38 + CGFloat(max(0, groupCount - 1)) * 10 + 8
            let listHeight = min(320, max(168, desiredHeight))

            TimelineView(.animation(minimumInterval: 1.0, paused: visibleRunning.isEmpty)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !visibleWaiting.isEmpty {
                            oledTaskGroup(title: "需要确认", color: BrandPalette.braunOrange, tasks: visibleWaiting, now: context.date, showClear: false)
                        }
                        if !visibleRunning.isEmpty {
                            oledTaskGroup(title: "正在运行", color: BrandPalette.telemetryCyan, tasks: visibleRunning, now: context.date, showClear: false)
                        }
                        if !visibleFinished.isEmpty {
                            oledTaskGroup(title: "已完成", color: .white.opacity(0.45), tasks: visibleFinished, now: context.date, showClear: true)
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
    }

    private func oledTaskGroup(title: String, color: Color, tasks: [AgentTask], now: Date, showClear: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("// \(title)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(color.opacity(0.85))
                Spacer()
                if showClear {
                    Button("清除") {
                        coordinator.clearFinishedTasks()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                } else {
                    Text(String(format: "%02d", tasks.count))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, task in
                    Button {
                        coordinator.focusTask(task)
                    } label: {
                        HStack(spacing: 9) {
                            StatusGlyphView(status: task.status, size: 13.5, animateRunning: true)
                            Text(task.title)
                                .font(.system(size: 12, weight: task.status == .waitingUser ? .semibold : .regular))
                                .foregroundStyle(task.status.isFinished ? .white.opacity(0.68) : .white.opacity(0.94))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if task.status == .running {
                                Text(formatElapsed(from: task.startedAt, to: now))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(BrandPalette.telemetryCyan)
                            }
                            Text(task.status == .waitingUser ? "\(task.key.source.oledCode) ↗" : task.key.source.oledCode)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(task.status == .waitingUser ? BrandPalette.braunOrange : .white.opacity(0.45))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if idx < tasks.count - 1 {
                        Rectangle()
                            .fill(.white.opacity(0.06))
                            .frame(height: 0.75)
                            .padding(.leading, 32)
                    }
                }
            }
            .background(
                (tasks.first?.status == .waitingUser ? BrandPalette.braunOrange.opacity(0.14) : Color.white.opacity(0.04)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        tasks.first?.status == .waitingUser ? BrandPalette.braunOrange.opacity(0.32) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
    }

    // MARK: - 3. Tactile Hardware Keep-Awake Keypad (15m / 30m / 60m / 永久)

    private var powerKeypadSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("防休眠档位")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if coordinator.powerSnapshot.isKeepingAwake {
                    Button("全部释放") {
                        coordinator.releaseAllKeepAwake()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(BrandPalette.braunOrange)
                } else {
                    Text("点选立即生效")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 3)

            HStack(spacing: 8) {
                ForEach([15, 30, 60], id: \.self) { mins in
                    let active = (activeTimedMinutes == mins)
                    Button {
                        coordinator.startTimedKeepAwake(minutes: mins)
                    } label: {
                        Text("\(mins)m")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(active ? .white : .primary.opacity(0.82))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8.5)
                            .background(hardwareKeyBackground(active: active, accent: false))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    coordinator.toggleManualKeepAwake()
                } label: {
                    Text(isManualActive ? "关闭" : "永久")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8.5)
                        .background(hardwareKeyBackground(active: isManualActive, accent: true))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 4. Bottom Micro Hardware Keys

    private var bottomMicroKeys: some View {
        HStack(spacing: 7) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                    Text("设置")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(microKeyBackground)
            }
            .buttonStyle(.plain)

            Button {
                if coordinator.alertsPaused {
                    coordinator.resumeAlerts()
                } else {
                    coordinator.pauseAlerts(minutes: 60)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: coordinator.alertsPaused ? "bell.slash.fill" : "bell")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(coordinator.alertsPaused ? BrandPalette.braunOrange : .primary.opacity(0.75))
                    Text(coordinator.alertsPaused ? "已静音" : "静音")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(coordinator.alertsPaused ? BrandPalette.braunOrange : .primary.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(microKeyBackground)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("退出")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(microKeyBackground)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func hardwareKeyBackground(active: Bool, accent: Bool) -> some View {
        if active {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 0.08, green: 0.085, blue: 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
        } else if accent {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.415, blue: 0.20), BrandPalette.braunOrange],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: BrandPalette.braunOrange.opacity(0.32), radius: 5, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(BrandPalette.cardFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 1)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 1, y: 1)
        }
    }

    private var microKeyBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(BrandPalette.cardFill(for: colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(BrandPalette.cardBorder(for: colorScheme), lineWidth: 0.9)
            )
    }

    private var oledPowerText: String {
        if coordinator.powerSnapshot.isAutoBlockedByLowBattery {
            return "低电量已熔断防休眠"
        }
        if coordinator.powerSnapshot.isKeepingAwake {
            if isManualActive { return "防休眠 · 永久开启" }
            if let reason = coordinator.powerSnapshot.primaryReason { return reason }
            return "防休眠 · 自动护航"
        }
        return "系统正常节能"
    }

    private var compactQuotaText: String? {
        var parts: [String] = []
        if coordinator.settings.showDeepSeekBalance, let bal = coordinator.deepseekBalance {
            parts.append("DS \(bal.formattedTotal)")
        }
        if coordinator.settings.showCodexQuota, let q = coordinator.codexQuota, let p = q.primaryRemainingPercent {
            parts.append("CDX \(p)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatElapsed(from start: Date, to now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        let mins = secs / 60
        let rem = secs % 60
        if mins >= 60 {
            return String(format: "%d:%02d:%02d", mins / 60, mins % 60, rem)
        }
        return String(format: "%02d:%02d", mins, rem)
    }
}
