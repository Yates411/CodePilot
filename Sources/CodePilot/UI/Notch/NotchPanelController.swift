import AppKit
import CodePilotCore
import CoreGraphics
import SwiftUI

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Container view that occupies the full fixed transparent canvas,
/// passes clicks outside the visible notch rect straight through to underlying apps,
/// and tracks pointer enter/exit strictly within the active notch silhouette.
@MainActor
private final class NotchHitTestView: NSView {
    var activeRect: NSRect = .zero {
        didSet {
            if activeRect != oldValue {
                rebuildTrackingArea()
            }
        }
    }

    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isCurrentlyInside = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard activeRect.width > 0, activeRect.height > 0 else {
            return nil
        }
        let hitZone = activeRect.insetBy(dx: -4, dy: -4)
        guard hitZone.contains(localPoint) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        guard activeRect.width > 0, activeRect.height > 0 else {
            if isCurrentlyInside {
                isCurrentlyInside = false
                onHoverChange?(false)
            }
            return
        }

        let zone = activeRect.insetBy(dx: -4, dy: -4)
        var options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways
        ]

        // Preserve inside state across morph geometry updates without spurious exit flashes.
        if let win = window {
            let mouseInWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
            let mouseLocal = convert(mouseInWindow, from: nil)
            if zone.contains(mouseLocal) {
                options.insert(.assumeInside)
                isCurrentlyInside = true
            }
        }

        let area = NSTrackingArea(rect: zone, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isCurrentlyInside = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isCurrentlyInside = false
        onHoverChange?(false)
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var mode: NotchDisplayMode = .hidden
    @Published var hasHardwareNotch: Bool = false
    @Published var notchHeight: CGFloat = 32
    @Published var physicalNotchWidth: CGFloat = 186
    @Published var targetSize: CGSize = .zero
    @Published var isExpandingTransition: Bool = false
}

@MainActor
final class NotchPanelController {
    private static let canvasSize = CGSize(width: 500, height: 460)

    private let coordinator: AppCoordinator
    private let stateController: NotchStateController
    private let viewModel = NotchViewModel()
    private var panel: NotchPanel?
    private var hitTestContainer: NotchHitTestView?
    private var hostingView: NSHostingView<NotchContentView>?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var activeAppObserver: NSObjectProtocol?
    private var isStarted = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.stateController = NotchStateController()
        self.stateController.onModeChange = { [weak self] mode in
            self?.render(mode: mode)
        }
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        stateController.isEnabled = coordinator.settings.notchEnabled
        stateController.fullScreenBehavior = coordinator.settings.notchFullScreenBehavior
        refreshFullScreenState()
        syncIndicatorState()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFullScreenState()
                self?.render(mode: self?.stateController.mode ?? .hidden)
            }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFullScreenState()
            }
        }

        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFullScreenState()
            }
        }
    }

    func stop() {
        isStarted = false
        stateController.cancelAllTimers()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); spaceObserver = nil }
        if let o = activeAppObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); activeAppObserver = nil }
        panel?.orderOut(nil)
        panel = nil
        hitTestContainer = nil
        hostingView = nil
    }

    func syncSettings(_ settings: AppSettings) {
        stateController.isEnabled = settings.notchEnabled
        stateController.fullScreenBehavior = settings.notchFullScreenBehavior
        refreshFullScreenState()
        render(mode: stateController.mode)
    }

    func syncIndicatorState() {
        let hasActive = !coordinator.tasks.isEmpty || coordinator.powerSnapshot.isKeepingAwake
        stateController.hasWaitingTask = coordinator.waitingUserCount > 0
        stateController.hasActiveIndicator = hasActive
        if stateController.mode != .hidden {
            render(mode: stateController.mode)
        }
    }

    func showToast(for task: AgentTask) {
        let secs = coordinator.settings.notchToastDurationSeconds
        stateController.triggerToast(for: task, duration: .seconds(secs))
    }

    private func targetScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func notchMetrics(for screen: NSScreen) -> (hasNotch: Bool, height: CGFloat, physicalWidth: CGFloat) {
        let topInset = screen.safeAreaInsets.top
        guard topInset > 0 else {
            return (false, 32, 0)
        }
        var physicalWidth: CGFloat = 186
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let computed = screen.frame.width - leftArea.width - rightArea.width
            if computed > 100 && computed < 320 {
                physicalWidth = computed
            }
        }
        return (true, topInset, physicalWidth)
    }

    private func refreshFullScreenState() {
        guard let screen = targetScreen() else {
            stateController.isFullScreenActive = false
            return
        }
        stateController.isFullScreenActive = Self.isFrontmostFullScreen(on: screen)
    }

    private static func isFrontmostFullScreen(on screen: NSScreen) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }
        let pid = frontApp.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenCGTop = primaryHeight - screen.frame.maxY
        let targetRect = CGRect(
            x: screen.frame.minX,
            y: screenCGTop,
            width: screen.frame.width,
            height: screen.frame.height
        )

        for win in list {
            guard let ownerPID = win[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            let widthMatch = abs(bounds.width - targetRect.width) <= 2
            let heightMatch = abs(bounds.height - targetRect.height) <= 2
            let originMatch = abs(bounds.minX - targetRect.minX) <= 2 && abs(bounds.minY - targetRect.minY) <= 2
            if widthMatch && heightMatch && originMatch {
                return true
            }
        }
        return false
    }

    private func ensurePanel() -> NotchPanel {
        if let existing = panel {
            return existing
        }

        let canvas = Self.canvasSize
        let p = NotchPanel(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false

        let container = NotchHitTestView(frame: NSRect(origin: .zero, size: canvas))
        container.autoresizingMask = [.width, .height]
        container.onHoverChange = { [weak self] inside in
            if inside {
                self?.stateController.pointerEntered()
            } else {
                self?.stateController.pointerExited()
            }
        }

        let contentView = NotchContentView(
            coordinator: coordinator,
            viewModel: viewModel,
            onSelectTask: { [weak self] task in
                self?.stateController.collapseNow()
                self?.coordinator.focusTask(task)
            }
        )
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(origin: .zero, size: canvas)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        p.contentView = container
        panel = p
        hitTestContainer = container
        hostingView = hosting
        return p
    }

    private func render(mode: NotchDisplayMode) {
        guard mode != .hidden, let screen = targetScreen() else {
            viewModel.mode = .hidden
            hitTestContainer?.activeRect = .zero
            panel?.orderOut(nil)
            return
        }

        let metrics = notchMetrics(for: screen)
        let size = targetNotchSize(for: mode, metrics: metrics)
        let canvas = Self.canvasSize
        let topInset: CGFloat = metrics.hasNotch ? 0 : 6
        let originX = screen.frame.midX - canvas.width / 2
        let originY = screen.frame.maxY - canvas.height - topInset
        let canvasFrame = NSRect(x: originX, y: originY, width: canvas.width, height: canvas.height)

        let p = ensurePanel()
        // Only move the fixed canvas when screen geometry actually changes (never during morph).
        if abs(p.frame.origin.x - canvasFrame.origin.x) > 0.5
            || abs(p.frame.origin.y - canvasFrame.origin.y) > 0.5
            || abs(p.frame.width - canvasFrame.width) > 0.5
            || abs(p.frame.height - canvasFrame.height) > 0.5 {
            p.setFrame(canvasFrame, display: true, animate: false)
        }

        let expanding = isExpanding(from: viewModel.mode, to: mode)
        viewModel.hasHardwareNotch = metrics.hasNotch
        viewModel.notchHeight = metrics.height
        viewModel.physicalNotchWidth = metrics.physicalWidth
        viewModel.isExpandingTransition = expanding

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            viewModel.mode = mode
            viewModel.targetSize = size
        } else {
            let anim: Animation = expanding
                ? .spring(response: 0.34, dampingFraction: 0.78)
                : .spring(response: 0.28, dampingFraction: 0.88)
            withAnimation(anim) {
                viewModel.mode = mode
                viewModel.targetSize = size
            }
        }

        // Update hit-test & tracking rect in AppKit bottom-left coordinates.
        let activeX = (canvas.width - size.width) / 2
        let activeY = canvas.height - size.height
        hitTestContainer?.activeRect = NSRect(x: activeX, y: activeY, width: size.width, height: size.height)

        p.orderFrontRegardless()
    }

    private func isExpanding(from oldMode: NotchDisplayMode, to newMode: NotchDisplayMode) -> Bool {
        rank(of: newMode) >= rank(of: oldMode)
    }

    private func rank(of mode: NotchDisplayMode) -> Int {
        switch mode {
        case .hidden: return 0
        case .collapsed: return 1
        case .toast: return 2
        case .expanded: return 3
        }
    }

    private func targetNotchSize(
        for mode: NotchDisplayMode,
        metrics: (hasNotch: Bool, height: CGFloat, physicalWidth: CGFloat)
    ) -> CGSize {
        switch mode {
        case .hidden:
            return .zero
        case .collapsed:
            let width = metrics.hasNotch ? (metrics.physicalWidth + 136) : 224
            return CGSize(width: width, height: metrics.height)
        case .toast:
            return CGSize(width: max(404, metrics.physicalWidth + 196), height: metrics.height + 74)
        case .expanded:
            let waiting = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .waiting)
                ? coordinator.tasks.filter { $0.status == .waitingUser }.count : 0
            let running = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .running)
                ? coordinator.tasks.filter { $0.status == .running }.count : 0
            let finished = (coordinator.selectedFilter == .all || coordinator.selectedFilter == .finished)
                ? min(coordinator.tasks.filter { $0.status.isFinished }.count, 6) : 0

            let totalVisible = waiting + running + finished
            let listH: CGFloat
            if totalVisible == 0 {
                listH = 44
            } else {
                let groups = (waiting > 0 ? 1 : 0) + (running > 0 ? 1 : 0) + (finished > 0 ? 1 : 0)
                let headerH: CGFloat = coordinator.selectedFilter == .all ? CGFloat(groups) * 18 : 0
                let rowsH = CGFloat(totalVisible) * 35
                let groupGaps = CGFloat(max(0, groups - 1)) * 9
                listH = min(196, headerH + rowsH + groupGaps + 4)
            }
            // notchHeight + tiles(60) + powerBar(30) + spacings & bottom padding(52) + listH
            return CGSize(width: 460, height: min(410, metrics.height + 142 + listH))
        }
    }
}
