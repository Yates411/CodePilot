import AppKit
import CodePilotCore
import Combine
import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case connections
    case power
    case notch
    case alerts
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: return "连接"
        case .power: return "防休眠"
        case .notch: return "刘海"
        case .alerts: return "提醒"
        case .general: return "通用"
        }
    }

    var icon: String {
        switch self {
        case .connections: return "powerplug"
        case .power: return "cup.and.saucer"
        case .notch: return "macbook"
        case .alerts: return "bell"
        case .general: return "gearshape"
        }
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published var runningCount: Int = 0
    @Published var confirmedRunningCount: Int = 0
    @Published var waitingUserCount: Int = 0
    @Published var powerSnapshot: PowerManagerSnapshot = PowerManagerSnapshot()
    @Published var batteryStatus: BatteryStatus? = BatteryMonitor.currentStatus()
    @Published var settings: AppSettings
    @Published var alertsPaused: Bool = false
    @Published var alertsPausedUntil: Date?
    @Published var selectedFilter: TaskFilterTab = .all {
        didSet {
            if selectedFilter != oldValue {
                notchController?.syncIndicatorState()
            }
        }
    }
    @Published var selectedSettingsSection: SettingsSection = .connections
    @Published var socketStatusText: String = "未启动"
    @Published var adapterHealth: [AgentSource: AdapterHealth] = [:]
    @Published var notificationAuthText: String = "未检测"
    @Published var notificationAuthorized: Bool = false
    @Published var lastPreviewFeedback: String?
    @Published var launchAtLoginEnabled: Bool = false
    @Published var launchAtLoginStatus: String = "未开启"
    @Published var deepseekBalance: DeepSeekBalanceSnapshot?
    @Published var deepseekBalanceError: String?
    @Published var hasDeepSeekKey: Bool = false
    @Published var deepseekKeyInput: String = ""
    @Published var codexQuota: CodexQuotaSnapshot?
    @Published var matchedProcessRules: [String] = []
    @Published var processRuleInput: String = ""
    @Published var copiedHookFeedback: String?
    @Published var isCheckingUpdate: Bool = false
    @Published var isInstallingUpdate: Bool = false
    @Published var updateStatusText: String?
    @Published var availableRelease: GitHubReleaseInfo?

    private let settingsStore = SettingsStore()
    private let taskStore: TaskStore
    private let powerManager: PowerAssertionManager
    private let processRuleMonitor = ProcessRuleMonitor()
    private let updateService = GitHubUpdateService()
    private let batteryMonitor = BatteryMonitor()
    private let frontmostMonitor = FrontmostAppMonitor()
    private let socketServer: UnixSocketServer
    private let adapters: [AgentSource: any AgentAdapter]
    private var runningAdapters: Set<AgentSource> = []
    private let notificationService = NotificationService()
    private let focusJumpService = FocusJumpService()
    private let launchAtLoginService = LaunchAtLoginService()
    private let keychainService = KeychainService()
    private let deepseekBalanceService = DeepSeekBalanceService()
    private let codexQuotaService = CodexQuotaService()
    private let deepseekKeyAccount = "deepseek-api-key"
    private var notchController: NotchPanelController?
    private var onboardingController: OnboardingWindowController?
    private var alertPauseResumeTask: Task<Void, Never>?
    private var quotaRefreshTask: Task<Void, Never>?
    private var processMonitorTask: Task<Void, Never>?
    private var alertCoordinator: DebouncedAlertCoordinator?
    private var setupTask: Task<Void, Never>?
    private var zombieSweepTask: Task<Void, Never>?
    private var settingsCommitTask: Task<Void, Never>?
    private var batterySyncTask: Task<Void, Never>?
    private var taskStoreListenerId: UUID?
    private var powerListenerId: UUID?
    private var wakeObserver: NSObjectProtocol?
    private var lastLowBatteryAlerted = false
    private var lastDeepSeekLowAlerted = false
    private var lastCodexLowAlerted = false
    private var started = false
    private var isShuttingDown = false

    init() {
        let loaded = settingsStore.load()
        self.settings = loaded
        self.taskStore = TaskStore()
        self.powerManager = PowerAssertionManager(policy: loaded.toPowerPolicy())
        self.socketServer = UnixSocketServer()
        self.adapters = [
            .antigravity: AntigravityAdapter(),
            .deepseekHarness: DeepSeekHarnessAdapter(),
            .kimiCode: KimiCodeAdapter(),
            .workbuddy: WorkBuddyAdapter(),
            .codex: CodexAdapter(),
            .claudeCode: ClaudeCodeAdapter()
        ]
    }

    func health(for source: AgentSource) -> AdapterHealth {
        adapterHealth[source] ?? .idle
    }

    func startIfNeeded() {
        guard !started, !isShuttingDown else { return }
        started = true

        notificationService.requestAuthorizationIfAvailable { [weak self] text, allowed in
            self?.notificationAuthText = text
            self?.notificationAuthorized = allowed
        }
        refreshLaunchAtLoginStatus()

        let notif = notificationService
        let repeatPolicy = RepeatReminderPolicy(
            enabled: settings.repeatReminderEnabled,
            interval: .seconds(settings.repeatReminderIntervalSeconds),
            maxRepeats: settings.maxRepeatReminders
        )
        alertCoordinator = DebouncedAlertCoordinator(
            delay: .milliseconds(2500),
            repeatPolicy: repeatPolicy
        ) { [weak self] task, isRepeat in
            await MainActor.run {
                guard let self, !self.isShuttingDown, !self.alertsPaused else { return }
                let shouldPopupNotch: Bool
                switch task.status {
                case .waitingUser:
                    shouldPopupNotch = self.settings.notchAutoPopupOnWaiting
                case .completed, .error:
                    shouldPopupNotch = self.settings.notchAutoPopupOnComplete
                case .running:
                    shouldPopupNotch = false
                }
                if shouldPopupNotch {
                    self.notchController?.showToast(for: task)
                }
                _ = notif.notifyTask(
                    task,
                    isRepeat: isRepeat,
                    settings: self.settings
                )
            }
        }

        let notch = NotchPanelController(coordinator: self)
        self.notchController = notch
        notch.start()

        setupTask = Task { [weak self] in
            guard let self else { return }
            let tId = await self.taskStore.addListener { [weak self] snap in
                await self?.powerManager.updateRunningTaskCount(snap.confirmedRunningCount)
                await MainActor.run {
                    guard let self, !self.isShuttingDown else { return }
                    self.tasks = snap.tasks
                    self.runningCount = snap.runningCount
                    self.confirmedRunningCount = snap.confirmedRunningCount
                    self.waitingUserCount = snap.waitingUserCount
                    self.notchController?.syncIndicatorState()
                }
            }
            if self.isShuttingDown {
                await self.taskStore.removeListener(tId)
                return
            }
            self.taskStoreListenerId = tId

            let pId = await self.powerManager.addListener { [weak self] snap in
                await MainActor.run {
                    guard let self, !self.isShuttingDown else { return }
                    self.powerSnapshot = snap
                    self.notchController?.syncIndicatorState()
                }
            }
            if self.isShuttingDown {
                await self.powerManager.removeListener(pId)
                return
            }
            self.powerListenerId = pId
        }

        frontmostMonitor.start { [weak self] source in
            Task { [weak self] in
                await self?.alertCoordinator?.silenceReminders(for: source)
            }
        }

        batteryMonitor.start { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                self.batteryStatus = status
                let isLow = status.isOnBattery && status.percentage <= self.settings.lowBatteryThreshold
                if isLow && !self.lastLowBatteryAlerted {
                    self.lastLowBatteryAlerted = true
                    self.notificationService.notifyLowBatteryCutoff(
                        percentage: status.percentage,
                        notificationsEnabled: self.settings.notificationsEnabled
                    )
                } else if !isLow {
                    self.lastLowBatteryAlerted = false
                }
                self.batterySyncTask?.cancel()
                self.batterySyncTask = Task { [weak self] in
                    await self?.powerManager.handleBatteryUpdate(status)
                }
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.powerManager.handleSystemWake()
            }
        }

        do {
            try socketServer.start { [weak self] event in
                await self?.ingest(event: event)
            }
            socketStatusText = "已监听 \(socketServer.socketPath)"
        } catch {
            socketStatusText = "启动失败：\(error)"
        }

        syncAdapters()

        zombieSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !self.isShuttingDown else { break }
                _ = await self.taskStore.sweepZombies()
            }
        }

        hasDeepSeekKey = (keychainService.readSecret(account: deepseekKeyAccount) != nil)
        quotaRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshQuotasNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled, !self.isShuttingDown else { break }
                await self.refreshQuotasNow()
            }
        }

        processMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.pollProcessRulesOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !self.isShuttingDown else { break }
                await self.pollProcessRulesOnce()
            }
        }

        if !settings.hasCompletedOnboarding {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !self.isShuttingDown, !self.settings.hasCompletedOnboarding else { return }
                self.presentOnboarding()
            }
        }
    }

    func presentOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(coordinator: self) { [weak self] in
                self?.markOnboardingCompleted()
            }
        }
        onboardingController?.show()
    }

    private func markOnboardingCompleted() {
        guard !settings.hasCompletedOnboarding else { return }
        var copy = settings
        copy.hasCompletedOnboarding = true
        updateSettings(copy)
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        socketServer.stop()
        onboardingController?.close()
        onboardingController = nil
        notchController?.stop()
        notchController = nil
        for adapter in adapters.values {
            adapter.stop()
        }
        runningAdapters.removeAll()
        frontmostMonitor.stop()
        batteryMonitor.stop()
        zombieSweepTask?.cancel()
        zombieSweepTask = nil
        setupTask?.cancel()
        await setupTask?.value
        setupTask = nil
        batterySyncTask?.cancel()
        batterySyncTask = nil
        alertPauseResumeTask?.cancel()
        alertPauseResumeTask = nil
        quotaRefreshTask?.cancel()
        quotaRefreshTask = nil
        processMonitorTask?.cancel()
        processMonitorTask = nil

        if settingsCommitTask != nil {
            settingsCommitTask?.cancel()
            settingsCommitTask = nil
            settingsStore.save(settings)
        }

        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }

        await alertCoordinator?.cancelAll()

        if let tId = taskStoreListenerId {
            await taskStore.removeListener(tId)
            taskStoreListenerId = nil
        }
        if let pId = powerListenerId {
            await powerManager.removeListener(pId)
            powerListenerId = nil
        }

        await powerManager.releaseAll()
    }

    func previewAlert(status: TaskStatus) {
        let now = Date()
        let demo = AgentTask(
            key: TaskKey(source: .antigravity, sessionId: "preview-\(status.rawValue)", taskId: "main"),
            epoch: "preview",
            lastSeq: 1,
            title: status == .waitingUser ? "等你确认 · CodePilot 预览" : "任务完成 · CodePilot 预览",
            status: status,
            startedAt: now,
            updatedAt: now,
            lastHeartbeatAt: now,
            message: status == .waitingUser ? "鼠标移到刘海即可展开全部任务与防休眠控制" : "一轮测试任务已完成，点击即可跳回原窗口"
        )

        var parts: [String] = []
        let willNotchPopup = settings.notchEnabled && (
            status == .waitingUser ? settings.notchAutoPopupOnWaiting : settings.notchAutoPopupOnComplete
        )
        if willNotchPopup {
            notchController?.showToast(for: demo)
            parts.append("刘海弹出 \(settings.notchToastDurationSeconds) 秒")
        } else {
            parts.append("刘海未弹出（开关已关）")
        }

        let notifResult = notificationService.notifyTask(demo, isRepeat: false, settings: settings)
        parts.append(notifResult)
        lastPreviewFeedback = parts.joined(separator: " · ")
    }

    func previewSound(named name: String) {
        notificationService.previewSound(named: name, volume: settings.soundVolume)
    }

    func openSystemNotificationSettings() {
        notificationService.openSystemNotificationSettings()
    }

    func refreshNotificationAuth() {
        notificationService.refreshAuthorizationStatus { [weak self] text, allowed in
            self?.notificationAuthText = text
            self?.notificationAuthorized = allowed
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = launchAtLoginService.isEnabled
        launchAtLoginStatus = launchAtLoginService.statusDescription
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        _ = launchAtLoginService.setEnabled(enabled)
        refreshLaunchAtLoginStatus()
    }

    func pauseAlerts(minutes: Int) {
        alertPauseResumeTask?.cancel()
        alertsPaused = true
        let targetDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        alertsPausedUntil = targetDate
        alertPauseResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.alertsPaused = false
                self?.alertsPausedUntil = nil
            }
        }
    }

    func resumeAlerts() {
        alertPauseResumeTask?.cancel()
        alertPauseResumeTask = nil
        alertsPaused = false
        alertsPausedUntil = nil
    }

    func saveDeepSeekAPIKey() {
        let trimmed = deepseekKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-"), trimmed.count >= 10 else {
            deepseekBalanceError = "API Key 应以 sk- 开头"
            return
        }
        do {
            try keychainService.saveSecret(trimmed, account: deepseekKeyAccount)
            deepseekKeyInput = ""
            hasDeepSeekKey = true
            deepseekBalanceError = nil
            Task { [weak self] in
                await self?.refreshQuotasNow()
            }
        } catch {
            deepseekBalanceError = "保存到钥匙串失败：\(error.localizedDescription)"
        }
    }

    func deleteDeepSeekAPIKey() {
        keychainService.deleteSecret(account: deepseekKeyAccount)
        hasDeepSeekKey = false
        deepseekBalance = nil
        deepseekBalanceError = nil
        deepseekKeyInput = ""
    }

    func refreshQuotasNow() async {
        if settings.codexEnabled && settings.showCodexQuota {
            let service = codexQuotaService
            let quota = await Task.detached(priority: .utility) {
                service.readLatestQuota()
            }.value
            if !isShuttingDown {
                codexQuota = quota
                evaluateCodexQuotaAlert(quota)
            }
        } else {
            codexQuota = nil
        }

        guard settings.showDeepSeekBalance,
              let key = keychainService.readSecret(account: deepseekKeyAccount) else {
            deepseekBalance = nil
            return
        }

        do {
            let snap = try await deepseekBalanceService.fetchBalance(apiKey: key)
            if !isShuttingDown {
                deepseekBalance = snap
                deepseekBalanceError = nil
                evaluateDeepSeekBalanceAlert(snap)
            }
        } catch {
            if !isShuttingDown {
                deepseekBalanceError = error.localizedDescription
            }
        }
    }

    func addWatchedProcess() {
        let name = processRuleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !settings.watchedProcessNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            var copy = settings
            copy.watchedProcessNames.append(name)
            updateSettings(copy)
            Task { [weak self] in
                await self?.pollProcessRulesOnce()
            }
        }
        processRuleInput = ""
    }

    func removeWatchedProcess(_ name: String) {
        var copy = settings
        copy.watchedProcessNames.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        updateSettings(copy)
        Task { [weak self] in
            await self?.pollProcessRulesOnce()
        }
    }

    func copyEmitHookCommand() {
        let binPath = Bundle.main.executablePath ?? "/Applications/CodePilot.app/Contents/MacOS/CodePilot"
        let cmd = "\"\(binPath)\" emit --source custom --status completed --title \"任务已完成\" --message \"来自终端/Hook\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        copiedHookFeedback = "已复制 CLI Hook 命令到剪贴板"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.copiedHookFeedback = nil
        }
    }

    var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.4.0"
    }

    func checkForUpdates() {
        guard !isCheckingUpdate, !isInstallingUpdate else { return }
        let repo = settings.githubUpdateRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else {
            updateStatusText = "请先填写 GitHub 仓库（格式：用户名/CodePilot）"
            return
        }

        isCheckingUpdate = true
        updateStatusText = "正在向 GitHub 查询最新版本…"
        availableRelease = nil

        let service = updateService
        let version = currentAppVersion
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCheckingUpdate = false }
            do {
                let result = try await service.checkForUpdate(repository: repo, currentVersion: version)
                switch result {
                case .upToDate(_, let latest):
                    self.availableRelease = nil
                    self.updateStatusText = "当前已是最新版本（v\(latest)）"
                case .updateAvailable(let info):
                    self.availableRelease = info
                    self.updateStatusText = "发现新版本 \(info.tagName)（当前 v\(version)）"
                }
            } catch {
                self.availableRelease = nil
                self.updateStatusText = error.localizedDescription
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableRelease, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateStatusText = "正在下载并校验 \(release.tagName) 安装包…"

        let service = updateService
        let bundleURL = Bundle.main.bundleURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await service.downloadAndInstall(release: release, currentAppURL: bundleURL)
                self.updateStatusText = "更新包已就绪，正在重启应用完成升级…"
                try? await Task.sleep(for: .milliseconds(450))
                NSApp.terminate(nil)
            } catch {
                self.isInstallingUpdate = false
                self.updateStatusText = error.localizedDescription
            }
        }
    }

    func openReleasePage() {
        if let url = availableRelease?.releaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func pollProcessRulesOnce() async {
        guard settings.processRulesEnabled, !settings.watchedProcessNames.isEmpty else {
            if !matchedProcessRules.isEmpty {
                matchedProcessRules = []
            }
            await powerManager.syncProcessRules(matchedProcesses: [])
            return
        }
        let rules = settings.watchedProcessNames
        let monitor = processRuleMonitor
        let matched = await Task.detached(priority: .utility) {
            monitor.matchingRules(watchedNames: rules)
        }.value
        guard !isShuttingDown else { return }
        if matchedProcessRules != matched {
            matchedProcessRules = matched
        }
        await powerManager.syncProcessRules(matchedProcesses: matched)
    }

    private func evaluateDeepSeekBalanceAlert(_ snap: DeepSeekBalanceSnapshot) {
        guard settings.lowBalanceAlertEnabled, !alertsPaused else { return }
        if snap.totalBalance < settings.deepseekLowBalanceThreshold {
            guard !lastDeepSeekLowAlerted else { return }
            lastDeepSeekLowAlerted = true
            notificationService.notifyLowQuota(
                identifier: "codepilot-low-deepseek-balance",
                title: "CodePilot · DeepSeek 余额预警",
                body: "当前 DeepSeek 余额仅剩 \(snap.formattedTotal)，已低于阈值 \(Int(settings.deepseekLowBalanceThreshold))。",
                notificationsEnabled: settings.notificationsEnabled
            )
        } else if snap.totalBalance >= settings.deepseekLowBalanceThreshold + 2.0 {
            lastDeepSeekLowAlerted = false
        }
    }

    private func evaluateCodexQuotaAlert(_ quota: CodexQuotaSnapshot?) {
        guard settings.lowBalanceAlertEnabled, !alertsPaused, let quota else { return }
        let threshold = settings.codexLowQuotaThreshold
        let lowPrimary = (quota.primaryRemainingPercent ?? 100) <= threshold
        let lowSecondary = (quota.secondaryRemainingPercent ?? 100) <= threshold
        if lowPrimary || lowSecondary {
            guard !lastCodexLowAlerted else { return }
            lastCodexLowAlerted = true
            let pText = quota.primaryRemainingPercent.map { "5h \($0)%" } ?? ""
            let sText = quota.secondaryRemainingPercent.map { "周 \($0)%" } ?? ""
            let detail = [pText, sText].filter { !$0.isEmpty }.joined(separator: " / ")
            notificationService.notifyLowQuota(
                identifier: "codepilot-low-codex-quota",
                title: "CodePilot · Codex 额度预警",
                body: "当前 Codex 剩余额度较低（\(detail)），请注意合理分配任务。",
                notificationsEnabled: settings.notificationsEnabled
            )
        } else if (quota.primaryRemainingPercent ?? 100) >= threshold + 5
                    && (quota.secondaryRemainingPercent ?? 100) >= threshold + 5 {
            lastCodexLowAlerted = false
        }
    }

    func toggleManualKeepAwake() {
        let isManualActive = powerSnapshot.activeLeases.contains { $0.kind == .manualIndefinite }
        Task {
            if isManualActive {
                await powerManager.releaseManualIndefinite()
            } else {
                let level: PowerAssertionLevel = settings.autoPreventDisplaySleep ? .systemAndDisplay : .systemOnly
                await powerManager.acquireManualIndefinite(level: level, reason: "手动防休眠")
            }
        }
    }

    func startTimedKeepAwake(minutes: Int) {
        let level: PowerAssertionLevel = settings.autoPreventDisplaySleep ? .systemAndDisplay : .systemOnly
        Task {
            await powerManager.acquireManualTimed(
                duration: .seconds(minutes * 60),
                level: level,
                reason: "定时防休眠（\(minutes) 分钟）"
            )
        }
    }

    func releaseAllKeepAwake() {
        Task {
            await powerManager.releaseAll()
        }
    }

    func clearFinishedTasks() {
        Task {
            _ = await taskStore.clearFinished()
        }
    }

    func focusTask(_ task: AgentTask) {
        Task {
            _ = await focusJumpService.focusApp(for: task)
            if task.status.isFinished {
                _ = await taskStore.acknowledgeRead(.userConfirmed(task.key))
            }
        }
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        settingsCommitTask?.cancel()
        settingsCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
            self.settingsStore.save(self.settings)
            self.syncAdapters()
            self.notchController?.syncSettings(self.settings)
            await self.powerManager.updatePolicy(self.settings.toPowerPolicy())
            await self.alertCoordinator?.updateRepeatPolicy(RepeatReminderPolicy(
                enabled: self.settings.repeatReminderEnabled,
                interval: .seconds(self.settings.repeatReminderIntervalSeconds),
                maxRepeats: self.settings.maxRepeatReminders
            ))
        }
    }

    private func isAdapterEnabled(_ source: AgentSource) -> Bool {
        switch source {
        case .antigravity: return settings.antigravityEnabled
        case .deepseekHarness: return settings.deepseekHarnessEnabled
        case .kimiCode: return settings.kimiCodeEnabled
        case .workbuddy: return settings.workbuddyEnabled
        case .codex: return settings.codexEnabled
        case .claudeCode: return settings.claudeCodeEnabled
        case .custom: return true
        }
    }

    private func syncAdapters() {
        for (source, adapter) in adapters {
            let shouldRun = isAdapterEnabled(source)
            let isRunning = runningAdapters.contains(source)
            if shouldRun && !isRunning {
                adapter.start { [weak self] event in
                    Task { [weak self] in
                        await self?.ingest(event: event)
                    }
                }
                runningAdapters.insert(source)
            } else if !shouldRun && isRunning {
                adapter.stop()
                runningAdapters.remove(source)
            }
            adapterHealth[source] = adapter.healthStatus
        }
    }

    private func ingest(event: TaskEvent) async {
        let shuttingDown = await MainActor.run { self.isShuttingDown }
        guard !shuttingDown else { return }
        let outcome = await taskStore.apply(event)
        if case .applied(let previous, let current, let shouldNotify) = outcome {
            await alertCoordinator?.handleTransition(
                previousStatus: previous,
                current: current,
                shouldNotify: shouldNotify
            )
        }
    }
}
