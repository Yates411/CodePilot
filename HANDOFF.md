# CodePilot 项目交接文档（HANDOFF）

> **更新日期**：2026-11-24  
> **当前版本**：`v0.4.0`（方向 A 视觉体系 + 方向 B 核心功能 + 方向 C 开源发布基础设施全部落地；Git 仓库已推送至 `Yates411/CodePilot`）  
> **项目路径**：`/Users/tianye/.gemini/antigravity/scratch/CodePilot`  
> **前置会话**：[049814db-bfe4-4216-9e8f-63bd1f3ddab4](conversation://049814db-bfe4-4216-9e8f-63bd1f3ddab4)  
> **测试状态**：`35/35` 单元测试全部通过（Swift 6 严格并发 `0 warning`）

---

## 1. 产品定位与当前完成度

**CodePilot** 是一款面向多 AI Coding Agent 并行工作流的 **macOS 原生刘海 + 菜单栏任务中枢 & Amphetamine 级智能防休眠工具**（纯原生 Swift / SwiftUI / AppKit / IOKit，零 Electron / Node 运行时，100% 本地只读零侵入）。

### 已完成全部功能（v0.1 → v0.3.0）
1. **核心状态机（`TaskStore`）**：
   - `(source, sessionId, taskId)` 实体唯一键 + `epoch + seq` 防乱序与重启重置；
   - **Priming 三分类**（`isPriming` + `provenLive` + `confirmedRunningCount`），防止冷启动历史会话误弹窗或误触发防休眠；
   - **分级已读**（`.seenByApp` 仅停止重复提醒不误删红点；`.openedSession`/`.userConfirmed` 清除已完成）；
   - **僵尸任务巡检**（30s 周期 + `POSIXProcessInspector` 通过 `proc_pidinfo` 启动时间防 PID 复用 + 区分 `ESRCH`/`EPERM`/`unknown`）。
2. **Amphetamine 级防休眠引擎（`PowerAssertionManager`）**：
   - 基于 IOKit `IOPMAssertionCreateWithName` 的 **Lease 租约架构**（手动无限期 > 手动定时 > 进程规则 > AI 自动联动）；
   - Make-Before-Break 断言升级、单调时钟 `ContinuousClock` 宽限期、电池低电量（默认 20%）+5% 迟滞熔断、`NSWorkspace.didWakeNotification` 唤醒重建。
3. **6 大主力 AI 工具零侵入只读适配器 + 开放协议**：
   - `AntigravityAdapter`（`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`）
   - `DeepSeekHarnessAdapter`（`~/.dsh/storages/session_projcache/sessions/session-*.json`，纯只读不改 DSH 配置）
   - `KimiCodeAdapter`（`~/.kimi-code/session_index.jsonl` + `<sessionDir>/state.json`）
   - `WorkBuddyAdapter`（`~/.workbuddy/workbuddy.db` 短连接只读 WAL + 临时三件套快照 + `sessions/*.json` 降级）
   - `CodexAdapter`（`~/.codex/sessions/**/rollout-*.jsonl` + `state_5.sqlite` 短标题 + `codex://threads/<id>` 白名单跳转）
   - `ClaudeCodeAdapter`（`~/.claude/projects/**/*.jsonl` 过滤 `subagents`）
   - `UnixSocketServer`（`~/.codepilot/events.sock`，0700 目录 + 0600 权限 + `getpeereid` 同用户 UID 校验 + NDJSON）
   - `TitleSanitizer`（清洗 `<USER_REQUEST>` XML 标签、过滤 Codex 内部自动 Review prompt、>10min 旧会话自动归档防僵尸）。
4. **刘海交互中心 & 毛玻璃菜单栏 & 专业侧边栏设置页**：
   - `NotchShape`（Apple 原厂同款外翻内凹圆角 + `screen.safeAreaInsets.top` 像素级齐平物理刘海 + 无刘海屏降级顶部药丸）；
   - 三态交互（静默态左右耳 + 事件弹出 3/6/10s + 悬停 150ms 展开 / 300ms 收起）+ `CGWindowList` 全屏三选一避让；
   - 菜单栏与刘海同步配备 **「等你 / 在跑 / 完成」三格大数字总览看板（点击筛选）** + 紧凑防休眠条 + 内嵌快捷控制；
   - 侧边栏设置页（`连接 / 防休眠 / 刘海 / 提醒 / 通用`）+ `LaunchAtLoginService`（`SMAppService.mainApp`）+ 「试一下」联动诊断反馈 + 音效试听与音量 + 锁屏隐藏标题。
5. **余额与额度**：
   - `KeychainService` + `DeepSeekBalanceService`（API Key 仅存 macOS 钥匙串，每 10 分钟查余额）；
   - `CodexQuotaService`（纯本地读 rollout 末尾 512 KB `rate_limits`，零联网）。

---

## 2. 本机环境与踩坑铁律（新会话必读！）

> [!IMPORTANT]
> 以下 5 条是本机实测踩出来的硬铁律，务必严格遵守，切勿重复踩坑：

1. **构建方式**：本机仅有 `/Library/Developer/CommandLineTools`（Swift 6.4，无完整 Xcode.app），`swift build` / `swift test` 会因 CLT `libPackageDescription` ABI 符号错位失败。
   - ✅ **必须使用项目自带脚本**（底层调用 `swiftc -swift-version 6`）：
     - 编译 Debug：`./scripts/build.sh debug`
     - 打包 Release `.app` 并 ad-hoc 签名：`./scripts/bundle_app.sh release`
     - 编译并运行测试：`./scripts/test.sh`（注意下条 sandbox 规则）
   - `Package.swift` 仅作 Xcode 兼容保留。
2. **禁止使用 `@State` 与 `@Observable` 宏**：
   - 本机 CommandLineTools 缺少 `SwiftUIMacros` 编译器插件，在 SwiftUI View 中写 `@State` 或 `@Observable` 会编译报错 `plugin for module 'SwiftUIMacros' not found`。
   - ✅ **统一使用** `ObservableObject` + `@Published`（集中在 `AppCoordinator`）+ View 侧 `@ObservedObject` / `@StateObject`。
3. **沙盒与测试/截屏边界**：
   - 编译打包（`build.sh` / `bundle_app.sh`）全部在标准 Sandbox 内执行；
   - 运行 `CodePilotTests`（含真实 `AF_UNIX` `connect()`）、运行 `--smoke-power` / `pmset`、`open dist/CodePilot.app`、`screencapture` 需使用 `BypassSandbox: true`。
4. **屏幕录制自验能力已授权**：
   - 宿主环境已获 macOS「屏幕录制」权限；改完刘海或 UI 后可直接重启 `dist/CodePilot.app` + 用 `screencapture -x -R 420,0,630,160 /tmp/cp_check.png` 抓图并用 `read_file` 逐像素验收！
5. **macOS `MenuBarExtra` 懒加载陷阱**：
   - 应用后台服务必须在 `CodePilotAppDelegate.applicationDidFinishLaunching` 中启动（已在 `CodePilotEntry.swift` 实现），切勿挪回 `MenuBarExtra` 的 `.task`。

---

## 3. 代码与文档地图

### 核心代码结构
- `Sources/CodePilotCore/`（核心库，可完全独立单测）
  - `Core/Models/`：`TaskModels.swift`, `SettingsModels.swift`
  - `Core/StateMachine/`：`TaskStore.swift`, `ProcessInspector.swift`, `DebouncedPresenter.swift`, `NotchStateMachine.swift`
  - `Core/Power/`：`PowerLease.swift`, `PowerAssertionBackend.swift`, `PowerAssertionManager.swift`, `BatteryMonitor.swift`
  - `Ingestion/Protocol/`：`EventEnvelope.swift`, `UnixSocketServer.swift`
  - `Ingestion/Helpers/`：`FSEventWatcher.swift`, `JSONLTailer.swift`, `ReadOnlySQLite.swift`, `AdapterRefreshCoalescer.swift`, `TitleSanitizer.swift`
  - `Ingestion/Adapters/`：`AgentAdapter.swift`, `AntigravityAdapter.swift`, `DeepSeekHarnessAdapter.swift`, `KimiCodeAdapter.swift`, `WorkBuddyAdapter.swift`, `CodexAdapter.swift`, `ClaudeCodeAdapter.swift`
  - `Services/`：`NotificationService.swift`, `FocusJumpService.swift`, `FrontmostAppMonitor.swift`, `LaunchAtLoginService.swift`, `KeychainService.swift`, `DeepSeekBalanceService.swift`, `CodexQuotaService.swift`
- `Sources/CodePilot/`（App 壳与 UI）
  - `CodePilotEntry.swift`（`@main` + `CodePilotAppDelegate` + `MenuBarExtra` + `Settings` + `--smoke-power` / `--listen`）
  - `App/AppCoordinator.swift`（统一状态中心与生命周期管理）
  - `UI/Notch/`：`NotchPanelController.swift`, `NotchContentView.swift`
  - `UI/MenuBar/`：`MenuBarPopoverView.swift`
  - `UI/Settings/`：`SettingsView.swift`
- `Tests/CodePilotTests/`：`TestRunner.swift`（无第三方依赖异步 Runner，30 个用例）、`TaskStoreTests.swift`、`PowerAssertionManagerTests.swift`、`IngestionTests.swift`、`S2AdapterTests.swift`
- `scripts/`：`build.sh`、`test.sh`、`bundle_app.sh`、`mock_event.py`
- `docs/`（已归档的历史需求与技术文档）：`PRD.md`、`TECH_DESIGN.md`、`PRD_v0.2.md`、`TECH_DESIGN_v0.2.md`

---

## 4. 协作工作流约定（用户偏好）

1. **语言**：所有回复、文档、计划默认使用**简体中文**。
2. **双模型协同节奏**：
   - 大功能迭代先对齐「需求文档 → Codex 评审 → 技术文档 → Codex 评审 → 分阶段推进」；
   - 阶段编码完成后调用 `multi-agent-bridge` 的 `run_codex`（`sandbox: "read-only"`, `reasoning_effort: "low"`）做硬伤 Review；
   - **严格收敛纪律**：只修真正的 **P0/P1 硬伤**（崩溃/死锁/竞态/安全/明确功能 bug），绝不为风格或低价值 nit 来回折腾；无硬伤（`NO_BLOCKERS`）即果断收口。
   - 注意：`run_codex` 传 `session_id` 时本地 bridge 存在 `--color` 参数冲突，复审时直接新开一次 `run_codex`（不传 `session_id`）且限制每次审阅 ≤ 4 个文件以防 3 分钟超时。
3. **Git 仓库已就绪**：远程仓库为 `https://github.com/Yates411/CodePilot.git`（`origin/main`），`.gitignore` 已排除 `.build/` 与 `dist/`。

---

## 5. 最新已落地能力（v0.4.0+）

- **方向 A · 视觉质感跃迁（已完成 ✅）**：暖白陶瓷精密仪表图标（`Resources/AppIcon.icns` + `CFBundleIconFile=AppIcon` + `lsregister` 刷新）、4 枚原创音效、固定 `500×460` 透明刘海画布 + `NotchHitTestView` 精准穿透、4 态状态栏图标与纯黑 OLED 自适应 Popover、首次启动 3 步引导。
- **方向 B · 核心功能升级（已完成 ✅）**：进程触发防休眠（`ProcessRuleMonitor`）、菜单栏右键快捷菜单、`CodePilot emit` CLI 与一键复制 Hook、低余额/低额度预警、GitHub Releases 应用内自更新（`GitHubUpdateService`，默认 `Yates411/CodePilot`）。
- **方向 C · 开源发布基础设施（已完成 ✅）**：MIT License、`CONTRIBUTING.md`、`SECURITY.md`、中英双语 README、GitHub Actions CI/Release 流水线、Homebrew Cask 配方（`Formula/codepilot.rb`）。
- **状态同步与精准跳转增强（已完成 ✅）**：
  - `AntigravityAdapter` 审批/提问识别（`ask_question` / `BypassSandbox` / `RequestFeedback`）；
  - `JSONLTailer` 单行上限提至 `4 MB`、冷启动尾部窗口 `1 MB`，6 大适配器压缩 FSEvents 延迟并增加 3 秒轻量轮询兜底与静默归档，消除「已完成仍显示正在运行」；
  - `FocusJumpService` 支持原生 Session Deep Link（`codex://threads/<id>`、`claude://code/continue?session=<id>`）、`iTerm2`/`Terminal` Tab 精准切换与 macOS Accessibility（`AXUIElement`）多窗口标题/目录匹配聚焦。
