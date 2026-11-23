import CodePilotCore
import SwiftUI

enum TaskFilterTab: String, CaseIterable {
    case all
    case waiting
    case running
    case finished
}

/// Apple-style notch silhouette with concave top shoulders that blend seamlessly
/// into the top bezel and smooth convex bottom corners.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topCornerRadius, rect.height / 2, rect.width / 4)
        let br = min(bottomCornerRadius, rect.height / 2, rect.width / 4)
        var p = Path()

        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

struct NotchContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var viewModel: NotchViewModel
    let onSelectTask: (AgentTask) -> Void

    private var waitingTasks: [AgentTask] {
        coordinator.tasks.filter { $0.status == .waitingUser }
    }

    private var runningTasks: [AgentTask] {
        coordinator.tasks.filter { $0.status == .running }
    }

    private var finishedTasks: [AgentTask] {
        coordinator.tasks.filter { $0.status.isFinished }
    }

    private var isManualKeepAwake: Bool {
        coordinator.powerSnapshot.activeLeases.contains { $0.kind == .manualIndefinite }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if viewModel.mode != .hidden && viewModel.targetSize.width > 0 {
                ZStack(alignment: .top) {
                    backgroundLayer

                    Group {
                        switch viewModel.mode {
                        case .hidden:
                            EmptyView()
                        case .collapsed:
                            collapsedBar
                                .transition(.opacity)
                        case .toast(let task):
                            toastContent(task: task)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        case .expanded:
                            expandedContent
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    }
                    .frame(width: viewModel.targetSize.width, height: viewModel.targetSize.height, alignment: .top)
                    .clipped()
                }
                .frame(width: viewModel.targetSize.width, height: viewModel.targetSize.height, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        let isCollapsed = (viewModel.mode == .collapsed)
        if viewModel.hasHardwareNotch {
            let topR: CGFloat = isCollapsed ? 7 : 12
            let bottomR: CGFloat = isCollapsed ? 12 : 24
            NotchShape(topCornerRadius: topR, bottomCornerRadius: bottomR)
                .fill(Color.black)
                .overlay(
                    NotchShape(topCornerRadius: topR, bottomCornerRadius: bottomR)
                        .stroke(Color.white.opacity(isCollapsed ? 0.0 : 0.10), lineWidth: 1)
                )
                .shadow(
                    color: .black.opacity(isCollapsed ? 0 : 0.52),
                    radius: isCollapsed ? 0 : 22,
                    y: isCollapsed ? 0 : 10
                )
        } else {
            let radius: CGFloat = isCollapsed ? 16 : 22
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(isCollapsed ? 0.08 : 0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
    }

    // MARK: - Collapsed (Minimal Left Ear, Clean Empty Right Ear)

    private var collapsedBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5.5) {
                Spacer(minLength: 0)
                if coordinator.waitingUserCount > 0 {
                    WaitingRingGlyph(size: 12.5, color: BrandPalette.braunOrange)
                    Text(formatBadgeCount(coordinator.waitingUserCount))
                        .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(BrandPalette.braunOrange)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if coordinator.runningCount > 0 {
                    RunningOrbitGlyph(size: 12.5, color: BrandPalette.telemetryCyan, animate: true)
                    Text(formatBadgeCount(coordinator.runningCount))
                        .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(BrandPalette.telemetryCyan)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if !finishedTasks.isEmpty {
                    CompletedCheckGlyph(size: 12.5, color: BrandPalette.emeraldGreen)
                    Text(formatBadgeCount(finishedTasks.count))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(BrandPalette.emeraldGreen)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity)

            if viewModel.hasHardwareNotch {
                Color.clear
                    .frame(width: viewModel.physicalNotchWidth)
            } else {
                Text("CODEPILOT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 8)
            }

            // Right ear stays intentionally clean and minimal in collapsed mode.
            Color.clear
                .frame(maxWidth: .infinity)
        }
        .frame(height: viewModel.notchHeight)
    }

    // MARK: - Event Toast

    private func toastContent(task: AgentTask) -> some View {
        VStack(spacing: 0) {
            collapsedBar
            Button {
                onSelectTask(task)
            } label: {
                HStack(spacing: 10) {
                    StatusGlyphView(status: task.status, size: 15, animateRunning: true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(task.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Text(task.key.source.oledCode)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(task.status == .waitingUser ? BrandPalette.braunOrange : .white.opacity(0.65))
                        }
                        Text(task.message ?? defaultMessage(for: task.status))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.60))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    (task.status == .waitingUser ? BrandPalette.braunOrange.opacity(0.14) : Color.white.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            task.status == .waitingUser ? BrandPalette.braunOrange.opacity(0.35) : Color.white.opacity(0.09),
                            lineWidth: 1
                        )
                )
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Expanded Panel (Option A: Precision 3-Tile Cards with Bottom Light Bar)

    private var expandedContent: some View {
        VStack(spacing: 11) {
            // Top bar aligned with hardware notch ears
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if coordinator.waitingUserCount > 0 {
                        WaitingRingGlyph(size: 12.5, color: BrandPalette.braunOrange)
                        Text("\(coordinator.waitingUserCount)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(BrandPalette.braunOrange)
                    } else if coordinator.runningCount > 0 {
                        RunningOrbitGlyph(size: 12.5, color: BrandPalette.telemetryCyan, animate: true)
                        Text("\(coordinator.runningCount)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(BrandPalette.telemetryCyan)
                    } else {
                        Text("CODEPILOT")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.hasHardwareNotch {
                    Color.clear.frame(width: viewModel.physicalNotchWidth)
                }

                HStack(spacing: 8) {
                    if !finishedTasks.isEmpty {
                        Button("清除") {
                            coordinator.clearFinishedTasks()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    }
                    if let battery = coordinator.batteryStatus {
                        Text("\(battery.percentage)%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                battery.isOnBattery && battery.percentage <= coordinator.settings.lowBatteryThreshold
                                    ? BrandPalette.braunOrange
                                    : .white.opacity(0.48)
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: viewModel.notchHeight)
            .padding(.horizontal, 34)

            // Option A: Precision 3-Tile Cards (Vector Icon + Big Mono Count + 2px Bottom Accent Bar)
            HStack(spacing: 8) {
                optionATile(
                    count: waitingTasks.count,
                    label: "等你确认",
                    status: .waitingUser,
                    accent: BrandPalette.braunOrange,
                    tab: .waiting
                )
                optionATile(
                    count: runningTasks.count,
                    label: "正在运行",
                    status: .running,
                    accent: BrandPalette.telemetryCyan,
                    tab: .running
                )
                optionATile(
                    count: finishedTasks.count,
                    label: "已完成",
                    status: .completed,
                    accent: BrandPalette.emeraldGreen,
                    tab: .finished
                )
            }
            .padding(.horizontal, 34)

            // Grouped Hairline Task Stream
            taskStreamSection
                .padding(.horizontal, 34)

            // Minimal Single-Line Keep-Awake Strip ("永久")
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    PowerArcGlyphView(
                        size: 12.5,
                        color: coordinator.powerSnapshot.isKeepingAwake ? BrandPalette.emeraldGreen : .white.opacity(0.42)
                    )
                    Text(powerShortStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(coordinator.powerSnapshot.isKeepingAwake ? .white.opacity(0.88) : .white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    ForEach([15, 30, 60], id: \.self) { mins in
                        Button("\(mins)m") {
                            coordinator.startTimedKeepAwake(minutes: mins)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.76))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    Button(isManualKeepAwake ? "关闭" : "永久") {
                        coordinator.toggleManualKeepAwake()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9.5)
                    .padding(.vertical, 3.5)
                    .background(
                        isManualKeepAwake ? Color.white.opacity(0.22) : BrandPalette.braunOrange,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
            }
            .padding(.top, 2)
            .padding(.horizontal, 34)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var taskStreamSection: some View {
        let visibleWaiting = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .waiting) ? waitingTasks : []
        let visibleRunning = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .running) ? runningTasks : []
        let visibleFinished = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .finished) ? finishedTasks : []
        let hasAny = !visibleWaiting.isEmpty || !visibleRunning.isEmpty || !visibleFinished.isEmpty

        if !hasAny {
            Text(coordinator.selectedFilter == .all ? "当前没有活跃任务" : "该分类下暂无任务（再点一次上方卡片切回全部）")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else {
            TimelineView(.animation(minimumInterval: 1.0, paused: visibleRunning.isEmpty)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if !visibleWaiting.isEmpty {
                            notchTaskGroup(title: "需要确认", color: BrandPalette.braunOrange, tasks: visibleWaiting, now: context.date)
                        }
                        if !visibleRunning.isEmpty {
                            notchTaskGroup(title: "正在运行", color: BrandPalette.telemetryCyan, tasks: visibleRunning, now: context.date)
                        }
                        if !visibleFinished.isEmpty {
                            notchTaskGroup(title: "已完成", color: .white.opacity(0.45), tasks: Array(visibleFinished.prefix(6)), now: context.date)
                        }
                    }
                }
                .frame(maxHeight: 196)
            }
        }
    }

    private func notchTaskGroup(title: String, color: Color, tasks: [AgentTask], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if coordinator.selectedFilter == .all {
                HStack {
                    Text("// \(title)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(color.opacity(0.85))
                    Spacer()
                    Text(String(format: "%02d", tasks.count))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 2)
            }

            VStack(spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, task in
                    Button {
                        onSelectTask(task)
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
                            Text(task.key.source.oledCode)
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
                (tasks.first?.status == .waitingUser ? BrandPalette.braunOrange.opacity(0.11) : Color.white.opacity(0.045)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        tasks.first?.status == .waitingUser ? BrandPalette.braunOrange.opacity(0.28) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
    }

    private func optionATile(
        count: Int,
        label: String,
        status: TaskStatus,
        accent: Color,
        tab: TaskFilterTab
    ) -> some View {
        let isSelected = (coordinator.selectedFilter == tab)
        return Button {
            coordinator.selectedFilter = isSelected ? .all : tab
        } label: {
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .center) {
                        StatusGlyphView(
                            status: status,
                            size: 15,
                            animateRunning: (status == .running && count > 0),
                            overrideColor: accent
                        )
                        Spacer()
                        Text("\(count)")
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .foregroundStyle(count > 0 || isSelected ? .white : .white.opacity(0.48))
                            .contentTransition(.numericText())
                    }
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.92) : .white.opacity(0.56))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Signature 2px precision bottom accent bar when selected
                if isSelected {
                    Capsule()
                        .fill(accent)
                        .frame(height: 2)
                        .padding(.horizontal, 12)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var powerShortStatus: String {
        if coordinator.powerSnapshot.isAutoBlockedByLowBattery {
            return "低电量已暂停防休眠"
        }
        if coordinator.powerSnapshot.isKeepingAwake {
            if isManualKeepAwake { return "防休眠 · 永久开启" }
            if let reason = coordinator.powerSnapshot.primaryReason { return reason }
            return "防休眠 · 自动"
        }
        return "正常节能"
    }

    private func defaultMessage(for status: TaskStatus) -> String {
        switch status {
        case .waitingUser: return "等待你确认或回复 · 点击跳转"
        case .running: return "正在执行中"
        case .completed: return "任务已完成 · 点击查看"
        case .error: return "执行异常 · 点击查看"
        }
    }

    private func formatBadgeCount(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private func formatElapsed(from start: Date, to now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        let mins = secs / 60
        let rem = secs % 60
        return String(format: "%02d:%02d", mins, rem)
    }
}
