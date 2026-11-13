# TextMate 通过 ACP 接入 Agent 的可行性分析

> 日期：2026-11-13 · 分析对象：TextMate 2 (master @ 16689b82)

## 一、结论

**可行，且 TextMate 的现有架构与 ACP 客户端需求的匹配度高于预期。**

- 推荐形态：应用内插件（`PlugIns/agent`，仿照现有 `PlugIns/dialog`），App 内嵌 ACP 客户端，agent 以子进程 + stdio JSON-RPC 方式接入。
- 分期落地：MVP（纯聊天）约 1–2 周；完整客户端（文件桥 + 权限 + diff）约 4–5 周；生产级（会话恢复 / 认证 / 计划面板等）约 5–8 周。
- 两个主要缺口：全库无 JSON/JSON-RPC 基础设施、无行内 diff 组件。均有可控补救路径（vendor 小型 JSON 库 + 自建 diff 视图）。
- 协议生态已成熟：ACP 由 Zed 于 2025-08 发布、现由 Zed + JetBrains 共同维护，v1 稳定运行一年以上，agent 侧（Gemini CLI、Claude Code、Codex、Copilot 等 40+）与 client 侧（Zed、JetBrains、Qt Creator 为生产级官方支持）均有大量先例。

## 二、ACP 协议现状

### 2.1 治理与版本

| 事项 | 现状 |
|---|---|
| 起源 | Zed 于 2025-08-27 发布（Gemini CLI 为首个参考实现），2025-09 加入 Claude Code，2025-10 加入 Codex |
| 治理 | 双首席维护者：Zed 的 Ben Brandt + JetBrains 的 Sergey Ignatov；RFD 流程；承诺走向独立基金会 |
| 版本策略 | 单整数版本号（当前 `protocolVersion: 1`），仅破坏性变更才递增；非破坏性新增走 capability 协商 |
| v2 | 草案进行中（约 45 个 RFD），将移除/改造 v1 的 File System、Terminals、Session Modes 部分 |
| SDK | TypeScript / Rust / Kotlin / Java / Python 官方库；**无 ObjC 库 → 协议层需自研** |
| 测试 | `acp-tck`（实验性）只测 agent 侧；**client 侧无官方 harness** |

### 2.2 客户端（即 TextMate）需实现的方法面

**发起方（调 agent）：**
- `initialize`（版本/能力协商）→ `session/new`（可选 `session/load` 恢复会话）
- `session/prompt`（发起一轮对话）、`session/cancel`（中断通知）
- 可选：`authenticate`（OAuth 等）

**响应方（agent 调 TextMate）：**
- `session/update`（接收）：消息块流（`agent_message_chunk` 等）、`tool_call` / `tool_call_update`、`plan`、`current_mode_update`、`usage_update` 等
- `session/request_permission`：工具调用前的权限弹窗（allow_once / allow_always 等选项）
- `fs/read_text_file` / `fs/write_text_file`：**可协商关闭**；开启后要求"含未保存的编辑器状态"读写
- 可选：`terminal/*`（复用 bundle command 基建即可）、`elicitation/create`（表单/URL 模式）

### 2.3 生态

- **Agent 侧**（丰富）：Gemini CLI（原生 `--experimental-acp`）、Claude Code（`claude-agent-acp` adapter）、Codex（`codex-acp`）、GitHub Copilot（public preview）、Goose、Qwen Code、OpenCode 等 40+；有官方 Registry。
- **Client 侧**：Zed、JetBrains AI Assistant、Qt Creator（生产级官方）；**Sublime Text / Neovim / Emacs / Pulsar / Obsidian 有社区插件**——"无官方支持的老牌编辑器接入 ACP"已有 Sublime 先例，证明此路径完全走得通。

## 三、TextMate 现有能力摸底

### 3.1 语言与构建

- 纯 Objective-C / ObjC++：0 个 Swift 文件、186 个 `.m`/`.mm`（不含 vendor）。
- **JSON 基础设施为零**：全库仅 [SoftwareUpdate.mm](Frameworks/SoftwareUpdate/src/SoftwareUpdate.mm) 用到 `NSJSONSerialization`；无任何 JSON-RPC / LSP 痕迹。
- vendor 目录已有第三方 C 库先例（Onigmo、kvdb）→ vendor 一个小型 JSON 库（json11 / yyjson）符合惯例。

### 3.2 子进程与流式 I/O —— ACP 连接层构件全部现成 ✅

- [runner.mm:16](Frameworks/command/src/runner.mm:16) `my_fork`：vfork + `io::create_pipe` + 关闭多余 fd + `setpgid`，stdout/stderr 分管——正是 ACP 需要的子进程形态。
- [runner.h:39](Frameworks/command/src/runner.h:39) `callback_t`（`output` / `done`）：现成的流式读回调模式，JSON-RPC 分帧器可直接套用。
- `Frameworks/io/`：pipe、exec、socket、[events.h:13](Frameworks/io/src/events.h:13)（FSEvent 监听，外部文件变更检测现成）。
- [RMateServer.mm](Applications/TextMate/src/RMateServer.mm)：应用内常驻 socket 服务的先例。

### 3.3 插件系统 —— 推荐落点 ✅

- [TMPlugInController.h:5](Applications/TextMate/src/TMPlugInController.h:5)：`TMPlugIn` 协议面极小（仅 `initWithPlugInController:`），bundle 从 `PlugIns/` 目录加载。
- [PlugIns/dialog](PlugIns/dialog/Dialog2.mm)（tm_dialog2）：完整先例——插件可注册 bundle 命令、访问应用服务、独立构建。
- 插件无生命周期钩子 → 通过 `NSDocumentController` 通知 / KVO 观察文档打开、保存、关闭。新插件 `PlugIns/agent` 与 app 解耦，不影响主程序。

### 3.4 文档模型 —— fs/* 与变更跟踪的关键落点 ✅

[OakDocument.h](Frameworks/document/src/OakDocument.h) 的 API 非常契合 ACP 文件桥需求：

| ACP 需求 | TextMate 对应 |
|---|---|
| `fs/read_text_file`（含未保存状态） | `content` 属性 / `enumerateByteRangesUsingBlock` 直接读 buffer |
| `fs/write_text_file` | `performReplacements:checksum:`（[OakDocument.h:104](Frameworks/document/src/OakDocument.h:104)）+ `beginUndoGrouping`/`endUndoGrouping`（[OakDocument.h:112](Frameworks/document/src/OakDocument.h:112)）—— agent 的写可作为一个可撤销编辑组 |
| 写后刷新与 diff 展示 | `OakDocumentContentDidChange` / `WillReload` / `DidReload` / `WillSave` / `DidSave` / `WillClose` 通知全有 |
| 外部变更检测 | `io/events` FSEvent watch |

### 3.5 UI 扩展点 —— 聊天面板 ⚠️ 可行但有技术债

- [HOBrowserView.h:5](Frameworks/HTMLOutput/src/browser/HOBrowserView.h:5)：HTML 输出用**旧版 WebKit `WebView`（非 WKWebView）** + `WebFrameLoadDelegate`；TextMate 已有 JS↔ObjC 双向桥先例（`TextMate.system` 等），[HOWebViewDelegateHelper.mm:105](Frameworks/HTMLOutput/src/browser/HOWebViewDelegateHelper.mm:105) 还记录了 WebView 复用的已知 WebKit bug 处理。
- [HTMLOutputWindow](Frameworks/HTMLOutputWindow/src/HTMLOutputWindow.mm) 是独立窗口控制器，聊天窗口可直接复制该模式。
- ACP 规定 agent 消息默认 Markdown → WebView 方案渲染免费；若走纯 AppKit（`NSTextView`）则需引入 Markdown→富文本转换。
- FileBrowser 无通用侧栏面板 API → 聊天面板建议做成独立窗口（复用 HTMLOutputWindow 模式）而非侧栏。
- 风险：legacy WebView 已 deprecated 且渲染性能一般（近期提交都在处理大文件性能）；MVP 可先用它求快，中期评估 WKWebView 重写或纯 AppKit。

### 3.6 diff 与权限

- diff：[scm/drivers/git.cc](Frameworks/scm/src/drivers/git.cc) + CommitWindow 表格式视图；**无行内 diff gutter 组件** → 最简方案：聊天流内渲染 unified diff 文本；进阶：自建行级 gutter。
- 权限弹窗：`session/request_permission` → `NSAlert` sheet（OakAppKit 有现成 NSAlert Additions），allow_once/allow_always 映射到按钮即可。

### 3.7 线程模型

buffer 编辑须在主线程；JSON-RPC 管道读在后台线程 → 统一 dispatch 到 main queue 更新 UI / buffer（参考 RMateServer 的线程纪律）。

## 四、推荐架构

```
PlugIns/agent（新插件，仿 PlugIns/dialog）
├── transport   JSON-RPC 2.0 over stdio（分帧 + 后台 dispatch queue，复用 io/pipe + runner 模式）
├── acp         协议状态机（initialize → session/new → prompt 循环、capability 协商、cancel）
├── bridge      文档桥（OakDocument ↔ fs/*；权限 → NSAlert sheet；通知挂点）
└── ui          聊天窗口（复用 HTMLOutput 模式或 AppKit）、tool call / plan 展示、diff 视图
```

Agent 配置：简单 JSON 配置文件（如 `~/.textmate/agents.json`），每项定义 `command` + `args`（如 `claude-agent-acp`、`codex-acp`、`gemini --experimental-acp`）。

**分期计划：**

| 阶段 | 内容 | 预估 |
|---|---|---|
| P0 MVP | stdio JSON-RPC + initialize/session/new/prompt/cancel + `agent_message_chunk` 聊天窗口 + agents.json | 1–2 周 |
| P1 完整客户端 | fs read/write 桥（未保存内容、写后 diff + undo group）+ 权限弹窗 + tool_call/plan 展示 | 2–3 周 |
| P2 打磨 | agentThought、usage、slash commands、`session/load` 恢复会话、authenticate（OAuth 开浏览器） | 1–2 周 |
| P3 可选 | `terminal/*`、elicitation、远程 agent（HTTP/WS） | 视需求 |

> P0 提示：若协商时**不上报** fs capability，agent 会退化为自带工具直接改文件（如 Claude Code 仍可用自身 shell 工具），配合 FSEvent/WillReload 刷新 buffer，效果先跑通——只是不经过 TextMate 文档模型、无 diff 高亮。

## 五、风险与难点

1. **协议演进**：v2 草案已启动。防波堤是单整数版本 + capability 协商——严格按协商结果降级即可。锁定 v1 起步，跟踪 RFD。
2. **旧 WebView 技术债**：若聊天 UI 复用 HTMLOutput 的 legacy WebView，长期要面对迁移；建议 MVP 先用，中期评估重写。
3. **无 ObjC SDK / JSON 库**：协议层为纯增量工作（无依赖冲突），JSON 编解码需 vendor 小库或手写——工作量可控但不可忽略（JSON-RPC 分帧、流式解析）。
4. **并发**：管道读线程 → 主线程 dispatch；`performReplacements:checksum:` 的 checksum 语义在并发写时需小心。
5. **安全**（ACP 安全页明确要求 client 自担）：session roots 之外的路径访问必须拒绝或弹窗；写版本控制 hooks / 编辑器设置 / agent 配置等敏感文件前必须询问。TextMate 侧要实现最小权限模型，不能全信 agent。
6. **测试面**：TCK 只覆盖 agent 侧；client 侧需自搭回放工具，或直接用 `claude-agent-acp` / `codex-acp` / Gemini CLI 三家实测。

## 六、与替代方案对比

| 方案 | 评价 |
|---|---|
| **ACP 客户端插件（推荐）** | 一套协议接入整个 agent 生态，支持会话/流式/权限/文件桥 |
| 仅做 MCP server（把 TextMate 文档暴露给外部 agent） | MCP 是 agent→工具协议，不提供编辑器侧的会话 UI 流；等于放弃 ACP 生态 |
| bundle command 式单发 AI 命令 | 实现最快，但无会话/流式/权限/文件桥，价值有限 |

## 参考

- [ACP 协议总览（v1）](https://agentclientprotocol.com/protocol/v1/overview) · [prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn) · [file system](https://agentclientprotocol.com/protocol/v1/file-system) · [elicitation](https://agentclientprotocol.com/protocol/v1/elicitation)
- [Agent 列表](https://agentclientprotocol.com/get-started/agents) · [Client 列表](https://agentclientprotocol.com/get-started/clients) · [治理](https://agentclientprotocol.com/community/governance) · [TCK 测试工具](https://agentclientprotocol.com/libraries/testing)
- [Zed 博客：Bring Your Own Agent to Zed（ACP 发布公告）](https://zed.dev/blog/bring-your-own-agent-to-zed) · [ACP 进展报告](https://zed.dev/blog/acp-progress-report)
