import Foundation

public enum NotchDisplayMode: Equatable, Sendable {
    case hidden
    case collapsed
    case toast(AgentTask)
    case expanded
}

/// Deterministic state machine for the Notch / Dynamic Island overlay.
/// Handles enter/exit hover debounce, toast timeout, and full-screen suppression.
@MainActor
public final class NotchStateController {
    public private(set) var mode: NotchDisplayMode = .hidden {
        didSet {
            if mode != oldValue {
                onModeChange?(mode)
            }
        }
    }

    public var isEnabled: Bool = true {
        didSet { reconcileBaseVisibility() }
    }
    public var fullScreenBehavior: FullScreenNotchBehavior = .hide {
        didSet { reconcileBaseVisibility() }
    }
    public var isFullScreenActive: Bool = false {
        didSet { reconcileBaseVisibility() }
    }
    public var hasWaitingTask: Bool = false {
        didSet { reconcileBaseVisibility() }
    }
    public var hasActiveIndicator: Bool = false {
        didSet { reconcileBaseVisibility() }
    }

    public var onModeChange: ((NotchDisplayMode) -> Void)?

    private let enterDelay: Duration
    private let exitDelay: Duration
    private let clock: ContinuousClock
    private var enterTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var isPointerInside = false

    public init(
        enterDelay: Duration = .milliseconds(150),
        exitDelay: Duration = .milliseconds(300),
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.enterDelay = enterDelay
        self.exitDelay = exitDelay
        self.clock = clock
    }

    isolated deinit {
        cancelAllTimers()
    }

    private var isSuppressed: Bool {
        guard isEnabled else { return true }
        guard isFullScreenActive else { return false }
        switch fullScreenBehavior {
        case .hide: return true
        case .waitingOnly: return !hasWaitingTask
        case .always: return false
        }
    }

    public func triggerToast(for task: AgentTask, duration: Duration) {
        guard !isSuppressed else { return }
        if mode == .expanded {
            // Do not interrupt user while hovering expanded panel.
            return
        }

        toastTask?.cancel()
        mode = .toast(task)
        toastTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            self?.onToastExpired()
        }
    }

    public func pointerEntered() {
        guard !isSuppressed else { return }
        isPointerInside = true
        exitTask?.cancel()
        exitTask = nil

        if case .toast = mode {
            toastTask?.cancel()
            toastTask = nil
            mode = .expanded
            return
        }

        guard mode == .collapsed else { return }
        enterTask?.cancel()
        enterTask = Task { [weak self, clock, enterDelay] in
            do {
                try await clock.sleep(for: enterDelay)
            } catch {
                return
            }
            guard let self, self.isPointerInside, !self.isSuppressed else { return }
            self.mode = .expanded
        }
    }

    public func pointerExited() {
        isPointerInside = false
        enterTask?.cancel()
        enterTask = nil

        guard mode == .expanded else { return }
        exitTask?.cancel()
        exitTask = Task { [weak self, clock, exitDelay] in
            do {
                try await clock.sleep(for: exitDelay)
            } catch {
                return
            }
            guard let self, !self.isPointerInside else { return }
            self.reconcileBaseVisibility(forceCollapse: true)
        }
    }

    public func collapseNow() {
        isPointerInside = false
        cancelAllTimers()
        reconcileBaseVisibility(forceCollapse: true)
    }

    public func cancelAllTimers() {
        enterTask?.cancel()
        enterTask = nil
        exitTask?.cancel()
        exitTask = nil
        toastTask?.cancel()
        toastTask = nil
    }

    private func onToastExpired() {
        toastTask = nil
        if isPointerInside {
            mode = .expanded
        } else {
            reconcileBaseVisibility(forceCollapse: true)
        }
    }

    private func reconcileBaseVisibility(forceCollapse: Bool = false) {
        if isSuppressed {
            cancelAllTimers()
            mode = .hidden
            return
        }

        if !forceCollapse {
            if case .toast = mode { return }
            if mode == .expanded { return }
        }

        mode = hasActiveIndicator ? .collapsed : .hidden
    }
}
