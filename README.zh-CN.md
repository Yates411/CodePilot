# CodePilot

**面向多 AI Coding Agent 并行工作流的 macOS 原生刘海 + 菜单栏任务中枢 & Amphetamine 级智能防休眠工具。**

[English](README.md) | 简体中文

[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6.0%20严格并发-F05138?style=flat-square&logo=swift)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-30D158?style=flat-square)](LICENSE)

---

## 为什么做 CodePilot？

当你同时并行开着 Antigravity、OpenAI Codex、Claude Code、DeepSeek Harness、Kimi Code、WorkBuddy 写代码时，最影响心流的两件事：

1. **切去干别的事后，漏掉后台会话的授权弹窗 / 决策提问 / 完成通知**；
2. **跑长编译或长 Agent 循环时，Mac 自动休眠导致任务中断**。

**CodePilot** 采用纯原生 **Swift 6 / SwiftUI / AppKit / IOKit** 构建，整包仅 **~4 MB**，零 Electron / Node 运行时，**100% 本地只读、零配置侵入、零对话内容上传**。

---

## 核心特性

- **物理刘海原生交互（连续弹簧 Morph 形变）**
  - 像素级齐平 MacBook 物理刘海（无刘海屏自动降级顶部圆角药丸），固定透明画布 + 精准 `hitTest` 点击穿透，绝不遮挡底层应用。
  - 折叠态左耳按优先级动态呈现精雕线性状态图标（`等你确认` > `正在运行` > `已完成`），右耳纯净留白；悬停丝滑弹簧展开三联卡 + 分组任务流 + 单行防休眠控制带。
- **Braun / Teenage Engineering 实体硬件风弹出台**
  - 暖白陶瓷（浅色）/ 阳极黑钛（深色）机身 + 嵌入式纯黑 OLED 屏 + 精雕矢量 Icon 筛选拨档 + 4 枚微凸实体防休眠按键（`15m` / `30m` / `60m` / `永久`）。
  - 状态栏图标支持**右键快捷菜单**，无需打开面板一键切换防休眠、静音或退出。
- **Amphetamine 级智能防休眠（IOKit Lease 租约引擎）**
  - 完整优先级链：`手动永久 > 手动定时 > 进程触发规则 > AI 自动联动`。
  - 基于 Darwin `libproc` 零 fork 轻量进程巡检（预设 `xcodebuild` / `swiftc` / `pytest` / `cargo` / `docker` / `ffmpeg`，支持设置页自定义增删），配备宽限期、低电量自动熔断（+5% 迟滞恢复）与休眠唤醒重建。
- **6 大主流 AI 工具零侵入只读适配 + 开放 CLI**
  - 自动捕获 Antigravity 的 `ask_question`、`BypassSandbox` 审批弹窗与 `RequestFeedback` 计划确认。
  - 提供 `CodePilot emit` 极简 CLI 子命令与设置页一键复制 Hook，方便社区接入 Cursor / Windsurf / Shell。
- **原创极简音效 & 低余额/额度主动预警**
  - 内置 4 枚原创极简音效（`Radar` / `Chime` 极短三连 / `Thud` / `Pulse`）；DeepSeek API Key 仅存 macOS 钥匙串，Codex 剩余额度纯本地零联网解析，支持低余额/低额度主动预警。

---

## 快速构建与安装

```bash
git clone https://github.com/your-org/CodePilot.git
cd CodePilot

# 运行全部 33 个单元测试
./scripts/test.sh

# 编译打包 Release .app 并 ad-hoc 签名
./scripts/bundle_app.sh release

# 安装到 /Applications 并启动
ditto dist/CodePilot.app /Applications/CodePilot.app
open /Applications/CodePilot.app
```

### 通过 CLI Hook 接入任意工具

```bash
/Applications/CodePilot.app/Contents/MacOS/CodePilot emit \
  --source custom \
  --status waiting_user \
  --title "构建完成，等待审阅" \
  --message "所有单元测试已通过"
```

---

## 隐私、安全与贡献

- **隐私安全**：详见 [SECURITY.md](SECURITY.md)（只读快照、钥匙串加密、`0600` + `getpeereid` Socket 鉴权、Deep-Link 严格白名单）。
- **新增适配器**：详见 [CONTRIBUTING.md](CONTRIBUTING.md) 中的「80 行 Swift 新增一个 AI 工具适配器指南」。

## 开源协议

MIT © 2026 CodePilot Contributors
