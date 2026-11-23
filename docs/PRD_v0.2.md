# CodePilot v0.2 体验跃迁版 · 产品需求文档（PRD）

> **版本**：v0.2.1（已完成 Codex 评审修订）  
> **前置版本**：[PRD.md](file:///Users/tianye/.gemini/antigravity/brain/6f63ee59-e1b9-4ebb-ab70-cc0ac9f82990/PRD.md)（v0.2 定稿） / v0.1 已完成底座（20/20 单测通过，M4 收口 Review 已全部修复）  
> **目标**：在**纯原生 Swift（~2 MB，零 112 MB Node 运行时包袱）+ 更安全的本地 Unix Socket** 基础上，实现 **体验追平并超越 Fire Ring（刘海动效 + 全工具覆盖）+ 独有 Amphetamine 智能防休眠闭环**。

---

## 1. 现状诊断与冲刺目标

### 1.1 v0.1 实测暴露的核心差距
1. **UI 布局 Bug**：菜单栏 `MenuBarPopoverView` 中 `ScrollView` 未设最小高度，导致任务列表被压成 0px，任务虽已触发防休眠但界面不可见。
2. **工具覆盖不足**：v0.1 仅接入 Antigravity，用户日常实际使用的 **DeepSeek Harness、Kimi Code、WorkBuddy、Codex、Claude Code** 尚未接通。
3. **缺少刘海核心体验与状态精致度**：缺少 Mac 刘海自动弹出、悬停展开、状态呼吸动效、首次启动基线（Priming）与切回原 App 自动消红点。

### 1.2 CodePilot v0.2 核心优势定位（对比 Fire Ring）

| 维度 | Fire Ring | CodePilot v0.2（我们的目标） |
| --- | --- | --- |
| **体积与性能** | 内嵌 112 MB Node.js + WKWebView | **纯原生 Swift / SwiftUI / AppKit（~2 MB）**，更低内存与 CPU |
| **支持工具** | Claude Code / Codex / DeepSeek Harness（3 款） | **Antigravity / DeepSeek Harness / Kimi Code / WorkBuddy / Codex / Claude Code（6 款）+ 开放 Unix Socket 协议** |
| **防休眠能力** | 无 | **独有 Amphetamine 级 Lease 智能防休眠**（AI 运行自动保活 + 宽限期 + 手动定时 + 低电量熔断） |
| **安全性与零侵入** | DSH 需改写 `package.json`；本地 HTTP 端口 | **全部只读零侵入**（DSH 直接读 `session_projcache` 明文缓存）；`0600` + `getpeereid` Unix Socket |

---

## 2. v0.2 核心升级需求

### 2.1 紧急体验修复与状态机升级（Priming 三分类 + 分级消红点 + 二次提醒前置）
1. **修复菜单栏列表塌陷**：为任务列表容器提供明确的动态高度计算与最小高度，确保 1 条到多条任务均清晰展示。
2. **首次启动基线（Priming 三分类，防止历史会话误触发防休眠）**：
   - **历史已存在**：冷启动扫描到的已完成/旧会话仅建立基线指纹，**不弹窗、不响铃、不触发防休眠**；
   - **可证明当前存活**：仅当通过有效文件锁、存活进程 PID 或启动后新到达的事件证实正在执行，才进入 `running` 并申请 `.aiAuto` 防休眠租约；
   - **无法确认状态**：冷启动时若日志停留在 `running` 但无近期写入/无存活锁，展示为历史/待确认态，**默认不续租防休眠**。
3. **分级已读消红点策略（防 IDE 误消）**：
   - `seen_by_app`（仅检测到前台切换到对应 App）：**只停止该工具的重复提醒**，不自动清除红点；
   - `opened_session`（检测到具体会话已打开，如 Codex 已读态）或 `user_confirmed`（用户点击卡片/通知跳转或手动清除）：真正消除 `completed` 红点。
4. **超时二次提醒（前置至 S1 实现）**：
   - 当任务处于 `waiting_user` 超过可配置时长（默认 5 分钟）未处理，自动发起温和二次提醒（最多 3 次，切入对应 App 或状态变化后立即停止）。

---

### 2.2 6 大主力 AI 工具零侵入适配器矩阵

全部遵循**只读零侵入、不改写宿主配置、不读取任何凭据**原则：

| 工具 | 实测本地只读数据源 | 状态判定核心逻辑 | 跳转方式 | 冲刺阶段 |
| --- | --- | --- | --- | --- |
| **DeepSeek Harness** | `~/.dsh/storages/session_projcache/sessions/session-*.json`（明文投影缓存，含 `turnBoundary` / `userQuestions` / `title` / `cwd`）+ `session.lock` 辅助 | `userQuestions` 未答 → `waiting_user`；`turnBoundary` 进行中/存在活跃锁 → `running`；回合结束 → `completed` | 激活 `DeepSeek Harness.app` | **S1** |
| **Antigravity** | `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl` | 兼容 `USER_INPUT` / `PLANNER_RESPONSE` / `GENERIC`；含 `ask_question` → `waiting_user`；工具调用中 → `running`；`DONE` 无挂起工具 → `completed` | 激活 `Antigravity.app` | **S1** |
| **Kimi Code** | `~/.kimi-code/session_index.jsonl`（`sessionId`/`sessionDir`/`workDir`）+ `sessions/` + `locks/` | 按 `locks/` 与最新会话记录判定 `running` / `waiting_user` / `completed`，展示 `workDir` 项目名 | 激活 `Kimi Code.app` 或终端 | **S2** |
| **WorkBuddy** | `~/.workbuddy/workbuddy.db`（WAL 短连接只读 `sessions` / `session_turn_interruptions` / `automation_runtime_state`）+ `sessions/*.json` | `session_turn_interruptions` 未决 → `waiting_user`；活跃会话/自动化运行 → `running`；结束 → `completed` | 激活 `WorkBuddy.app` | **S2** |
| **Codex** | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` + `state_5.sqlite`（短连接只读 `threads.name`）+ `.codex-global-state.json`（已读态） | 解析 `task_started` / `task_complete` / `turn_aborted` / `request_user_input` / `*approval_request`（过滤 subagent） | `codex://threads/<id>` 精准直达 | **S2** |
| **Claude Code** | `~/.claude/projects/**/*.jsonl`（忽略 `subagents`）+ `~/Library/Application Support/Claude/claude-code-sessions/local_*.json` | `tool_use`/`pause_turn` → `running`；未回复 `AskUserQuestion`/`ExitPlanMode` → `waiting_user`；完成 → `completed`；20 分钟无写入静默 `stale` | `claude://code/continue?session=<desktopId>` 或激活终端 | **S2** |

---

### 2.3 刘海（Notch）交互中心 + 高质感原生 UI 重做

#### 1. 刘海悬浮窗（`NotchPanelController`）
- **物理融入**：纯黑圆角底部造型，精准对齐 `NSScreen.safeAreaInsets.top` 刘海几何位置；外接无刘海显示器自动降级为屏幕顶部居中黑色胶囊药丸。
- **三态交互**：
  1. **静默态（Collapsed）**：无任务且未开防休眠时完全隐身；有状态时在刘海左右两侧极简显示：
     - 左侧：状态指示（红点/蓝火苗跳动/绿勾 + 数量）；
     - 右侧：防休眠微标（绿光咖啡杯/闪电，一眼看清 Mac 正在防休眠）。
  2. **事件弹出态（Toast）**：当任意任务进入 `waiting_user` / `completed` / `error` 时，刘海平滑向下展开卡片（工具徽标 + 标题 + 状态说明 + 耗时），停留 **3 / 6 / 10 秒**（可配）后自动收起。
  3. **悬停展开态（Expanded）**：鼠标移入刘海停留 ~150ms 平滑展开完整面板：
     - 顶部：**防休眠快捷控制条**（一键切换 / 定时倒计时 / 宽限期倒计时）+「全部清除」；
     - 下方：按 `等你` → `在跑` → `异常` → `完成` 分组的任务卡片，点击直接跳转回对应 App/会话。
- **全屏避让**：检测到前台为全屏应用（视频/会议/全屏 IDE）时自动收起刘海不遮挡内容，仅保留系统通知和菜单栏状态。

#### 2. 菜单栏 Popover 视觉重做
- 彻底修复 0 高度塌陷问题；
- 与刘海统一的高质感深色/跟随系统卡片样式；
- 运行中任务实时显示已运行耗时（如 `01:24`）和柔和呼吸动效；
- 防休眠卡片实时显示定时剩余时间或宽限期倒计时。

---

### 2.4 Amphetamine 防休眠体验深化
- 在刘海静默态与展开态均透出防休眠状态，无需点开菜单栏也能确认「后台跑测试时 Mac 不会休眠」；
- 顶部防休眠条支持一键切换「防系统休眠（允许息屏）」与「同时防息屏」；
- 在设置页支持配置 **按工具独立开关** 与 **实时健康诊断**（显示每个工具检测到了多少近期活跃会话）。

---

## 3. v0.2 冲刺推进节奏（S1 → S2 → S3 → S4）

每一阶段完成后都能直接打包实机验证，不再等到最后才看到效果：

| 阶段 | 核心交付 | 验收方式 |
| --- | --- | --- |
| **S1 · 立即止血 + 状态机升级 + DeepSeek & Antigravity 实机打通** | 修复菜单栏 `ScrollView` 0 高度 Bug + Priming 三分类基线 + `waiting_user` 超时二次提醒 + 接入 **DeepSeek Harness**（`session_projcache` + 锁新鲜度校验）+ 优化 **Antigravity** 适配器 + 任务实时耗时显示 | 打包打开 `CodePilot.app`，**直接用你本机的 DeepSeek Harness 和 Antigravity 真实跑任务**，立刻在菜单栏看到实时状态、超时二次提醒与自动防休眠！ |
| **S2 · 全主力工具大满贯 + 分级消红点** | 接入 **Kimi Code**、**WorkBuddy**（WAL 短连接只读 + `sessions/*.json` 降级）、**Codex**、**Claude Code** 4 大适配器 + URL Scheme 精准跳转 + 工具连接页实时诊断 + 分级已读消红点 | 6 大工具全部可独立开关并显示健康状态，实测 Kimi Code / WorkBuddy / Codex 真实会话。 |
| **S3 · 刘海（Notch）交互中心 + 高质感 UI 重做** | 实现 `NotchPanelController`（可开关、enter 150ms / exit 300ms 防闪烁、固定主屏/刘海屏防跨屏漂移、全屏避让、无刘海药丸降级）+ 融合刘海防休眠控制条 + 菜单栏视觉精修 | 实机体验刘海自动弹出、悬停展开、全屏自动收起、点击跳回对话。 |
| **S4 · 全量测试 + Codex 收口 Review + v0.2 打包** | 补齐 6 大适配器与刘海核心逻辑单元测试、调用 Codex 做 v0.2 Code Review 并修复全部 P0/P1、产出 `CodePilot.app` v0.2 | 全量测试通过 + 实机日常可用。 |

---

## 4. 确认后立即开冲
如果这份 v0.2 需求与 `S1 → S2 → S3 → S4` 冲刺节奏符合你的预期，回复 **「开始 S1」**，我立刻先修掉菜单栏高度 Bug 并把 **DeepSeek Harness + Antigravity** 实机打通给你验收！
