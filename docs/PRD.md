# 产品需求文档（PRD）：AI Coding 任务中枢与智能防休眠工具

> **版本**：v0.2（已完成本机实测 + GPT/Codex 架构交叉评审，正式定名 `CodePilot`）  
> **应用名称**：`CodePilot`  
> **工程目录**：`/Users/tianye/.gemini/antigravity/scratch/CodePilot`  
> **目标平台**：macOS 14+（Apple Silicon 优先，可编译 Universal）  
> **技术路线**：原生 Swift + SwiftUI + AppKit + IOKit（洁净室从零实现，100% 本地运行）

---

## 1. 产品背景与定位

### 1.1 一句话定位
一款面向 **多 AI Coding Agent 并行工作流** 的 macOS 菜单栏 + 刘海伴侣工具：把本机所有 AI 编程助手的任务状态统一收口，并与 **Amphetamine 级别的智能防休眠** 深度联动。

### 1.2 核心痛点
1. **多 Agent 切换心智负担重**：同时开着 Antigravity、WorkBuddy、Kimi Code、Codex、Claude Code、DeepSeek Harness 跑不同任务，切去查资料或开会后，不知道哪个还在跑、哪个卡在「等你确认」、哪个已经完成。
2. **后台跑任务被系统休眠打断**：让 AI 后台跑测试、重构或长任务时，Mac 自动锁屏/休眠导致断网或任务中断；而单独使用 Amphetamine 经常「忘了开」或「开了忘了关导致电池耗干」。
3. **工具碎片化**：现有同类工具多为闭源，只覆盖 2~3 款工具，无法接入 Antigravity、WorkBuddy、Kimi Code 等日常主力工具。

### 1.3 设计原则
- **本地优先、隐私零外泄**：所有会话状态仅在本机解析与展示，不上传任何对话内容，不消耗模型 Token。
- **零侵入只读**：读取各工具 SQLite / JSONL 时严格短连接只读，绝不阻塞 checkpoint 或损坏宿主数据。
- **开放可扩展**：以 **Unix Domain Socket** 作为正式本地协议，辅以 JSON 目录调试适配器，未来新工具可低成本接入。

---

## 2. 本机 AI 工具接入可行性与分期（基于本机实测）

| 工具 | 实测本机位置 / 数据特征 | 推荐接入方式 | 可行性 | 分期 |
| --- | --- | --- | --- | --- |
| **Antigravity** | `/Applications/Antigravity.app`、`Antigravity IDE.app`；`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl` + 支持原生 Hooks | Hooks 推送到 Unix Socket（首选）+ `FSEvents` 监听 `transcript.jsonl` | ✅ 极高 | **v0.1 (MVP)** |
| **Kimi Code** | `/Applications/Kimi Code.app`、`~/.kimi-code/bin/kimi`；`~/.kimi-code/session_index.jsonl`（`sessionId`/`sessionDir`/`workDir`）、`sessions/`、`locks/` | `FSEvents` 增量监听 `session_index.jsonl` 与活跃 `sessionDir` | ✅ 极高 | **v0.2** |
| **WorkBuddy** | `/Applications/WorkBuddy.app`；`~/.workbuddy/workbuddy.db`（WAL SQLite，含 `sessions`/`session_turn_interruptions`/`automation_runtime_state`）、`sessions/*.json`、`tasks/` | SQLite 短连接只读 + 退避重试 + `sessions/` 目录监听 | ✅ 极高 | **v0.2** |
| **Codex** | `~/.codex/session_index.jsonl`、`sessions/`、`state_5.sqlite`、`thread_history_1.sqlite`、`queue_1.sqlite` | `FSEvents` 监听 `session_index.jsonl` + SQLite 短连接只读 | ✅ 极高 | **v1.0** |
| **DeepSeek Harness** | `/Applications/DeepSeek Harness.app`；`~/.dsh/sessions/<workspace>/`、`storages/` | `FSEvents` 监听 `sessions/` 会话变更 | ✅ 高 | **v1.0** |
| **Claude Code** | `~/.claude/` + 原生 Hooks（`PreToolUse` / `Notification` / `Stop`） | 官方 Hooks 推送到 Unix Socket | ✅ 极高 | **v1.0** |
| **Kimi（通用桌面端）** | `/Applications/Kimi.app`、`~/.kimi-cu/`（偏向桌面/Web 客户端） | 评估 `~/Library/Application Support` 缓存或辅助功能/浏览器桥接 | ⚠️ 中低 | **v2.0** |

---

## 3. 核心架构与功能需求

### 3.1 统一任务状态机（Core State Machine）

#### 1. 实体与一致性设计
- **唯一键**：以 `(source, sessionId, taskId)` 建立任务实体。
- **防乱序回退**：每条状态事件携带单调递增的 `seq` 或高精度 `timestamp`，状态机拒绝旧序号事件覆盖新状态。
- **4 种核心状态**：
  - `waiting_user`（等你，红色）：AI 提问、等待确认方案或批准操作。
  - `running`（在跑，蓝色）：模型思考、工具调用或后台子任务运行中。
  - `completed`（完成，绿色）：本轮任务正常结束；用户跳回或查看后自动清理，支持一键全部清除。
  - `error`（异常，橙色）：任务失败、超时、配额耗尽或进程异常退出。
- **僵尸任务防护**：结合心跳时间戳 + 宿主进程存活检测，若任务长时间无心跳（默认 10 分钟）且对应进程已退出，自动降级为 `completed` 或 `error`，避免永远卡在 `running` 导致防休眠不释放。
- **UI 防抖与状态解耦**：状态机内部实时精确流转；**2~3 秒去抖（Debounce）仅用于 UI 弹窗与音效触发**，避免工具调用间隙高频闪烁。

#### 2. 本地数据采集健壮性规范
- **SQLite WAL 只读（WorkBuddy / Codex）**：
  - 禁止长期持有数据库连接（防止阻塞宿主 WAL checkpoint）。
  - 采用 **短连接 + 只读模式（`SQLITE_OPEN_READONLY`）+ 退避重试**，对 `SQLITE_BUSY` 与表结构升级（schema 变更）做容错降级。
- **JSONL 增量读取（Antigravity / Kimi Code / Codex）**：
  - 记录文件 inode + 读取偏移量，妥善处理追加、半行截断、重复行幂等、编码异常与文件轮转（rotation）。

---

### 3.2 开放本地事件协议（Open Event Protocol）

- **主协议（正式推荐）**：**Unix Domain Socket**（例如 `~/Library/Application Support/CodePilot/events.sock`，`0600` 本机用户权限隔离）。
  - 零端口占用与暴露风险，支持低延迟实时推送、心跳与双向 ACK。
  - 标准 JSON 载荷包含：`protocolVersion`、`eventType`（`upsert` / `heartbeat` / `remove`）、`source`、`sessionId`、`taskId`、`seq`、`title`、`status`、`appBundleId`、`cwd`、`pid`、`timestamp`。
- **辅助调试协议**：同步提供可选的 **JSON 文件目录监听适配器**（如 `~/.codepilot/events/*.json`），方便用户写简单 shell hook 或排障，暂不引入本地 HTTP 服务。

---

### 3.3 智能防休眠模块（Amphetamine 融合 · Lease 架构）

底层采用 macOS IOKit 原生 `IOPMAssertionCreateWithName`，**严禁各业务模块直接创建/释放系统断言**，必须由全局唯一的 **`PowerAssertionManager`（Lease 租约管理器）** 统一管控：

#### 1. Lease（租约）优先级与并发模型
所有触发源各自申请和释放独立 Lease，只要存在 `≥ 1` 个有效 Lease，管理器即持有系统级 IOKit 断言：
1. **手动无限期 Lease**（最高优先级，仅由用户手动关闭）。
2. **手动定时 Lease**（15m / 30m / 1h / 2h / 自定义 / 到指定时刻，到期自动回收）。
3. **进程触发 Lease**（V1：如 `xcodebuild`、`pytest`、`docker`、`cargo` 等运行期间持有）。
4. **AI 自动联动 Lease**（由状态机托管：只要任意任务为 `running` 即持有；最后一个 `running` 任务结束后进入 **宽限期（默认 3 分钟）**，若宽限期内有新任务变为 `running` 则立即取消倒计时继续持有，否则到期仅释放自动 Lease）。

#### 2. 息屏策略与安全熔断
- **息屏粒度**：
  - 默认：`kIOPMAssertionTypePreventUserIdleSystemSleep`（防系统休眠，允许屏幕熄灭省电）。
  - 可选：`kIOPMAssertionTypePreventUserIdleDisplaySleep`（同时防止息屏）。
- **低电量熔断**：电池电量低于阈值（默认 **20%**，可配）时，**自动熔断 AI 自动联动 Lease** 并发送系统通知；手动保活 Lease 是否同步熔断由用户在设置中显式开关（默认不强行打断手动保活，仅弹窗预警）。
- **异常安全**：应用正常或异常退出时，macOS 内核自动回收进程持有的 IOKit 断言，不会残留永久防休眠；同时监听系统唤醒/电源切换通知，及时重建或校准断言状态。

---

### 3.4 UI 与交互设计（菜单栏核心 + 刘海增强）

#### 1. 菜单栏（一等核心入口，v0.1 交付）
- 常驻 SwiftUI `MenuBarExtra`，图标随状态动态变色并带防休眠微标。
- 左键弹出主面板：
  - 顶部：**防休眠状态条**（显示当前生效的 Lease 原因，如 `防休眠中 · 因 Antigravity 运行中` 或 `手动保活 · 剩余 42 分钟` + 一键开关/定时选择）。
  - 中部：按 `等你` → `在跑` → `异常` → `完成` 分组展示任务列表，点击直接跳回原 App。
  - 底部：一键清除已完成、暂停提醒、设置入口。
- 右键快捷菜单：快速开关防休眠、暂停提醒、打开设置、退出。

#### 2. 刘海悬浮窗（增强展示层，v0.2 交付）
- 基于无边框 `NSPanel`，配合 `collectionBehavior` 与 `NSApplication.didChangeScreenParametersNotification` 动态适配多屏、分辨率切换、带刘海机型与无刘海机型（无刘海屏降级为顶部居中悬浮药丸）。
- **静默态**（仅在有任务或防休眠开启时极简显示） / **弹出提醒态**（停留 3/6/10 秒） / **悬停展开态**。
- **全屏避让**：检测到前台全屏应用时自动隐藏刘海弹窗，避免遮挡视频、共享屏幕或全屏 IDE（系统通知与菜单栏仍正常工作）。

---

### 3.5 提醒与一键跳转

- **通知与音效**：支持 macOS 原生通知、按工具独立开关、勿扰/暂停提醒；v0.2 增加区分「等你/完成」的提示音和温和二次提醒（`waiting_user` 超时未处理）。
- **一键跳转**：
  - v0.1：通过 `NSWorkspace` 激活对应桌面 App（`Antigravity.app`、`WorkBuddy.app`、`Kimi Code.app` 等）。
  - v1.0：按需引导开启辅助功能权限，支持匹配终端（iTerm2 / Ghostty / Terminal / VS Code）具体窗口或 Tab。

---

## 4. 非功能需求与权限边界

1. **资源占用**：空闲 CPU < 1%，内存 < 80 MB。
2. **权限最小化**：
   - 核心功能（IOKit 防休眠 + 本地 Unix Socket + 读取本机日志）无需提权，采用非 App Store 沙盒模式本机自签/公证运行。
   - 通知权限、辅助功能权限（仅 v1.0 终端 Tab 跳转）均按需引导，拒绝授权不影响核心功能。
3. **隐私红线**：绝不读取任何 `credentials`、`auth.json`、`oauth`、`.credentials.yaml`、`server.token` 等凭据文件。

---

## 5. 分期交付路线图（经 GPT 评审精简）

| 阶段 | 目标范围 | 核心验收目标 |
| --- | --- | --- |
| **v0.1 (Core MVP)** | 统一状态机 + **Unix Socket 本地协议** + **Antigravity 适配器** + **菜单栏完整面板** + **Lease 架构防休眠（AI 自动联动 + 手动无限期/定时 + 低电量熔断）** + 系统通知与原 App 跳转 | 先把最核心的事件链路、防休眠租约生命周期和日常可用性跑通，立即可用于日常 Coding。 |
| **v0.2 (主力补齐 + 刘海)** | 接入 **Kimi Code**、**WorkBuddy** 适配器 + **刘海（Notch）悬浮交互** + 提示音与二次提醒 + JSON 调试适配器 | 覆盖你的 3 大主力工具并上线刘海体验。 |
| **v1.0 (全生态)** | 补齐 **Codex、DeepSeek Harness、Claude Code** + 进程触发防休眠 + 终端 Tab 精准跳转 + 全屏/多屏深度兼容 | 覆盖全部 6 款主力 Coding Agent，完全替代独立 Amphetamine。 |
| **v2.0 (进阶)** | 探索 **Kimi 桌面端（Kimi.app）** 适配 + 每日 AI 编码时长统计 + 可选 API 额度/余额提醒 | 升级为个人 AI 编程效率仪表盘。 |

---

## 6. GPT（Codex）交叉评审修订记录（v0.1 → v0.2）

- **防休眠重构为 Lease 架构**：明确手动无限期 / 手动定时 / 进程触发 / AI 自动各自维护独立租约，避免多源冲突与误释放，且低电量默认只熔断自动 Lease。
- **状态机与数据采集加固**：增加 `(source, sessionId, taskId)` 实体与单调序号防乱序；区分状态一致性与 UI 去抖；强制 SQLite 短连接只读防阻塞 WAL checkpoint；增加 JSONL 截断/轮转容错与僵尸任务清理。
- **协议收敛**：确立 Unix Domain Socket 为主协议 + JSON 目录为调试辅助，移除 HTTP 选项。
- **MVP 瘦身**：将刘海复杂多屏适配及 Kimi Code / WorkBuddy 适配器拆至 v0.2，让 v0.1 聚焦核心闭环更快跑通可用版本。

---

## 7. 已确认事项

1. **应用名称**：正式定名为 `CodePilot`。
2. **项目目录**：`/Users/tianye/.gemini/antigravity/scratch/CodePilot`。
3. **交付节奏**：按 **v0.1（Antigravity + 菜单栏 + Lease 防休眠）→ v0.2（Kimi Code + WorkBuddy + 刘海交互）→ v1.0（Codex / DSH / Claude Code）** 分阶段交付。
