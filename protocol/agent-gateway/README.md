# Orialis Agent Gateway protocol

本文档是 Orialis Server 与 Hermes Orialis 插件之间的非语音协议说明。
它同时记录当前可互操作的 v1 基线和 v0.3–v0.12 / v1.x 的后续扩展，状态
必须以本文件的“实现状态”列为准：路线图条目不是当前服务器已接受的帧。

## 实现状态

当前工作树的 Rust Agent Gateway parser 已接受 v1 基线帧、capability resume
控制帧和一组带序列的结构化事件；Hermes Orialis v0.2 适配器当前实际处理的
仍是基线消息/ACK/错误/保活。服务端对结构化事件已有解析、去重、gap 检查、
approval 超时和移动端通知钩子，但尚未把所有事件接入 Hermes 的业务执行器。

| 帧类型 | 方向 | 状态 | 语义 |
| --- | --- | --- | --- |
| `hello` | Hermes → Orialis | 已实现 | 注册设备与客户端元数据，必须是首帧 |
| `hello_ack` | Orialis → Hermes | 已实现 | 接受 v1 握手 |
| `ping` / `pong` | 双向 | 已实现 | WebSocket 保活 |
| `message.send` | Orialis → Hermes | 已实现 | 投递一个持久化的会话消息 |
| `message.ack` | Hermes → Orialis | 已实现 | 确认已收到，不代表处理完成 |
| `message.reply` | Hermes → Orialis | 已实现 | 回复一个 `message.send` |
| `error` | 双向 | 已实现 | 可恢复的协议或请求错误 |
| `event` | 双向 | Rust parser 已实现 | v0.3 通用事件信封，按 `event_type` 携带非语音 payload |
| `capabilities.hello` / `capabilities.ack` | 双向 | 服务端已实现 | 能力声明与按 `resume_from` 重放 |
| `agent.*` / `tool.*` | Hermes → Orialis | 服务端事件接收已实现 | 状态、流式输出和工具生命周期 |
| `clarify.*` / `approval.*` | 双向 | 传输与 approval 状态已实现 | 用户交互 UI/业务执行仍需接入 |
| `session.*` / `artifact.*` | 双向 | 结构解析与序列钩子已实现 | 完整业务执行仍需接入 |

当前 HTTP / 手机通道已经提供：

- `Authorization: Session <accessToken>`、`/api/v1/auth/session` 和 30 天 Session；
- `/api/v1/capabilities` 能力查询；
- `/api/v1/sync/events` 的用户级 `cursor` 增量事件与 `/api/v1/sync/snapshot`；
- `/api/v1/ws` 的 mobile envelope、heartbeat、`sync.change_hint` 和消息推送；
- HTTP 附件上传/下载，以及 Agent Gateway 中的附件元数据。

下表是版本路线图。`设计` 只表示字段和语义已固定，仍需实现和能力协商；
`已实现` 只用于当前代码已经提供并测试的能力。

| 版本 | 范围 | 状态 |
| --- | --- | --- |
| v0.3 | 扁平事件帧、字段命名、事件类型注册 | Rust parser/事件元数据已实现；插件业务分发未全接入 |
| v0.4 | 幂等键、请求关联、设备级 `seq` 与重放规则 | HTTP mutation/sync 已实现；Agent event sequence 已实现 |
| v0.5 | `clarify.request` / `clarify.response` / `clarify.cancel` | Rust/Python 校验已实现；客户端交互未接入 |
| v0.6 | `approval.request` / `approval.resolve` | Rust 去重、超时和 ACK 已实现；策略执行未接入 |
| v0.7 | `session.open`…`session.reply` 与 `session.*` 事件 | 传输类型已实现；HTTP access Session 另行实现 |
| v0.8 | `command.request` / `command.reply` 和工具状态 | Python helper 有定义；Rust Gateway 尚未接受 command 帧 |
| v0.9 | `cron.delivery`、proactive delivery | Python helper 有定义；当前无循环任务执行器 |
| v0.10 | Voice / 音频事件与附件 | **未实现且有意排除** |
| v0.11 | `artifact` / `artifact.event` 与文件产物元数据 | Rust/Python 校验已实现；通用产物执行未接入 |
| v0.12 | capabilities、fallback、客户端兼容矩阵 | HTTP capabilities 与 Agent resume 已实现 |
| v1.x | 兼容性冻结、跨平台实现与逐项能力发布 | 后续；不改变 v1 基线帧语义 |

## 传输和命名

- Agent WebSocket 地址是 `/api/v1/agent/ws`，只承载 UTF-8 JSON 文本帧；附件字节
  通过 Orialis Server HTTP 文件 API 传输。
- 所有 Agent 帧都带数字 `version: 1` 和字符串 `type`。Agent 帧的业务字段使用
  `snake_case`，以保持当前 Rust/Python 实现兼容；HTTP 和 mobile envelope 的
  字段使用 `camelCase` 或既有的 `request_id`，见各自文档。
- ID 是不透明字符串。`message_id`、`event_id`、`request_id`、`session_id` 和
  `run_id` 不得用显示名称替代，也不得由接收方重新生成关联 ID。
- 设备 ID 使用 `<USER>_<DEVICE>_<Agent>`，每段只允许 ASCII 字母或数字，长度
  2–24；总长度不超过 80。规范示例为 `JXCZ_MBA_Hermes` 和 `JXCZ_WIN_Hermes`。

## v1 基线帧字段

### 握手与保活

```json
{
  "version": 1,
  "type": "hello",
  "device_id": "JXCZ_MBA_Hermes",
  "client": "orialis-hermes-plugin",
  "plugin_version": "0.2.0",
  "platform": "macos",
  "capabilities": ["messages", "attachments"]
}
```

`hello` 必须是首帧；`platform` 当前使用 `macos` 或 `windows`。`capabilities` 可选，
但发送方不得声明尚未能处理的扩展。Orialis 返回
`{"version":1,"type":"hello_ack"}`；详细能力与续传使用 `capabilities.hello`。
当前 Python helper 的默认 `hello()` 会列出 helper 支持的扩展名称；这只是协议
能力声明，不等于当前 Hermes adapter 已接入对应业务 handler，具体以对端返回的
`capabilities.ack` 和兼容矩阵为准。
收到 `ping` 返回 `pong`；未知类型、错误
版本、缺字段或非法附件生成 `error`，不会要求插件进程退出。

### 消息、确认与错误

`message.send` 必须有非空 `message_id`、`conversation_id`，并且 `content` 非空
或至少有一个附件。`message.reply` 另外必须有 `reply_to`，且服务端只接受与原
`message_id` 和 `conversation_id` 都匹配的回复。

```json
{
  "version": 1,
  "type": "message.reply",
  "message_id": "msg_002",
  "reply_to": "msg_001",
  "conversation_id": "conv_001",
  "content": "Orialis 已完成分析。"
}
```

`message.ack` 的 `status` 当前为 `received`。ACK 只表示帧已被插件收到；断线、
超时或重复投递时，服务端仍以 `message_id` 及持久化投递队列判断最终状态。

### 附件

消息中的 `attachments` 是元数据数组，不是内联字节：

| 字段 | 类型 | 要求 |
| --- | --- | --- |
| `id` | string | Orialis Server 签发的附件 ID |
| `name` | string | 非空，最多 180 字符；接收端只当显示名 |
| `mime_type` | string | `image/*`、`text/*`、PDF、JSON、XML、ZIP 或 `application/octet-stream` |
| `size` | integer | 正整数，单文件不超过 20 MiB |
| `download_url` | string | Orialis Server 的绝对 HTTP(S) 地址 |

单条消息最多 16 个附件。图片、文本、文档和源文件允许；`audio/*`、`video/*`
以及 voice 类型永远不通过此协议。Hermes 回复附件必须先上传到 Orialis Server，
再把规范元数据放入 `message.reply`。

## v0.3 结构化事件帧

Orialis 同时保留两个兼容形态，均由 [`event-v1.schema.json`](schema/event-v1.schema.json)
覆盖：v0.3 的通用 `type: "event"` 信封，以及 v1.x 的命名扁平事件。新发送方
优先使用与对端 capability 匹配的命名扁平事件；不能协商时可使用通用信封。

通用信封字段：

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `version` | 是 | 固定为 `1` |
| `type` | 是 | 固定为 `event` |
| `event_id` | 是 | 事件的不透明 ID；重投不改变 |
| `event_type` | 是 | 已注册的点号名称，例如 `agent.delta` |
| `sequence` | 是 | 在事件流内严格递增的非零整数 |
| `occurred_at` | 是 | RFC 3339 时间 |
| `session_id` | 否 | Agent 执行会话 ID，不是 access token |
| `correlation_id` | 否 | 请求或运行关联 ID |
| `causation_id` | 否 | 直接触发本事件的事件 ID |
| `idempotency_key` | 否 | 可重试命令的幂等键 |
| `payload` | 是 | 与 `event_type` 对应的 JSON object |

命名扁平事件使用 `event_id`、`seq`、`session_id`，并把领域字段与 `type` 同级；
例如：

事件接收端先按 `event_id` 去重，再按 `sequence` 或 `seq` 检查顺序。缺口返回
`agent.ack.status="gap"` 与 `expected_seq`；重复事件返回 `duplicate`。当前
Rust parser 接受通用信封和命名扁平事件；Hermes v0.2 适配器业务层仍只处理基线消息。

```json
{
  "version": 1,
  "type": "agent.delta",
  "event_id": "evt_001",
  "seq": 12,
  "session_id": "sess_001",
  "run_id": "run_001",
  "delta": "Orialis 已完成"
}
```

## v0.4 幂等、关联和序列

### 幂等

- HTTP 业务写入用 `Idempotency-Key` 请求头；同一个逻辑写入在超时后复用原 Key，
  新逻辑必须生成新 Key。Key 按用户隔离，不能放进业务 JSON 代替请求头。
- 当前 Orialis Server 对已经写入同步事件的重复 Key 返回 `409`，错误信息为
  `Idempotency-Key was already used`；附件上传对同一用户、会话和 Key 保留原上传
  响应。客户端不能假定所有接口都会返回第一次响应，遇到 409 应读取资源或同步流
  确认结果。
- Agent 消息的去重键是 `message_id`。服务端投递队列、Hermes 重连和回复关联都
  复用它；`message.reply.message_id` 必须另行唯一，`reply_to` 指向原消息。

### 序列和游标

- `/api/v1/sync/events` 的 `cursor` 是每个 Orialis 用户独立的单调递增序列；响应
  的 `nextCursor` 是本页最后一个 cursor，没有事件时保持请求的 `after`。
- 命名扁平事件使用 `seq`，通用信封使用 `sequence`；当前服务端按设备保存
  命名事件的 inbound/outbound seq，并在连接恢复后按 `resume_from` 重放缓存事件。
  通用信封的 `sequence` 只在该信封事件流内排序。两者都不与实体 `version`、HTTP
  `cursor` 或旧 Fangcun `revision` 混用。
- 客户端只有在成功应用整页事件后保存 `nextCursor`。断线、超时、未知事件或
  解析失败时保留旧游标，重新拉取；游标不可恢复时使用 snapshot。

## v0.5–v0.11 事件语义

下表使用当前代码中的规范类型和字段。`agent.*`、`tool.*`、`clarify.*`、
`approval.*`、`session.*`、`artifact.*` 已进入 Rust 传输层；`command.*`、
`slash.*`、`delivery.*` 和 `cron.delivery` 目前只在 Python helper 的兼容集合中，
服务端 parser 尚未接受它们。

| 版本/领域 | 规范类型 | 必需字段（除公共字段外） | 当前状态 |
| --- | --- | --- | --- |
| v0.5 Agent | `agent.typing` | `conversation_id`, `typing`; 可选 `run_id` | Rust 可接收；插件业务处理未接入 |
| v0.5 Agent | `agent.start`, `agent.delta`, `agent.complete`, `agent.error`, `agent.status` | start/delta/complete/error 需 `run_id`；delta 需 `delta`；error 需 `code`,`message`；status 需 `status` | Rust 可接收 |
| v0.5 Tool | `tool.started`, `tool.progress`, `tool.completed`, `tool.failed` | `tool_call_id`；started 需 `tool_name`；failed 需 `code`,`message` | Rust 可接收 |
| v0.5 Clarify | `clarify.request`, `clarify.resolve`, `clarify.cancel` | request 需 `request_id`,`question`；resolve/cancel 需 `request_id`；可选 `choices`,`multi_select`,`response`,`reason` | Rust 可接收；需客户端 UI |
| v0.6 Approval | `approval.request`, `approval.resolve` | request 需 `request_id`,`action`；resolve 需 `request_id`,`decision` | Rust 可接收；按 request_id 单次解决并支持超时 |
| v0.7 Session | `session.start`, `session.update`, `session.complete`, `session.cancel`, `session.error` | update 需 object `update`；error 需 `code`,`message`；其余按类型带 `result`/`reason` | Rust 可接收 |
| v0.8 Command | `command.request`, `command.reply` | request 需 `request_id`,`command`；reply 需 `request_id`,`status`；可选 `args`,`content` | Python helper 有定义；Rust 未接受 |
| v0.9 Delivery | `delivery.send`, `delivery.ack`, `cron.delivery`, `proactive.delivery` | send 需 `delivery_id`,`conversation_id` 和文本/附件；ack 需 `delivery_id`,`status` | Python helper 有定义；无 cron 执行器 |
| v0.11 Artifact | `artifact`, `artifact.event` | `artifact_id`,`conversation_id`,`name`,`mime_type`，且有 `url`、`download_url` 或 `content` | Rust/Python 校验已实现 |

Python helper 还定义 `stream.start`、`stream.delta`、`stream.end` 和 `typing.start` /
`typing.stop` 兼容输入；其中 `typing.start` / `typing.stop` 会规范化为 `typing`，
而 `stream.*` 尚未被 Rust Gateway 接受。流式事件的 `stream_id` 必填，`stream.delta`
还需非空 `delta` 和非负 `sequence`；这不替代已实现的 Agent `seq`。

公共事件字段中的 `conversation_id`、`session_id` 和 `run_id` 均为不透明字符串；
事件文本最多 256 KiB，capability 最多 64 项，附件规则沿用本文件的 16 项/20 MiB
限制。当前代码还接受兼容别名：`agent.started`、`agent.completed`、`agent.failed`、
`session.created`、`session.started`、`session.completed`、`session.cancelled`、
`session.failed`、`artifact.created`；发送方应优先使用上表规范名称。

`approval.resolve.decision` 的规范值为 `once`、`session`、`always`、`deny`、
`timeout` 或 `cancelled`。`agent.ack` 的 `status` 为 `received`、`duplicate`、
`gap` 或 `unknown`；当状态为 `gap` 时必须带正整数 `expected_seq`。服务端会把
已接收的结构化事件转成 mobile `event` 通知，但 mobile 通知仍不是 HTTP 状态源。

v0.9 不会把现有任务的 `recurrence` 字符串误称为 cron 执行器；当前 Orialis Server
没有调度、触发、重试或后台执行。v0.10 Voice 仍然明确排除。

## v0.7 Session 与 v0.8 command

当前 Session 是 HTTP 认证对象：注册/登录返回 `accessToken` 与 `expiresAt`，客户端
使用 `Authorization: Session <accessToken>`，服务端只保存 token hash。事件中的
`session_id` 是 Agent 执行会话，不是 access token，也不能出现在日志或 URL。
Agent 侧的 `session.open`、`session.close`、`session.reset`、`session.list`、
`session.info` 请求以及 `session.reply` 响应由 Python helper 定义；服务端 Rust
结构化生命周期事件使用上一节的 `session.start` 等类型，二者在 v1.x 冻结前必须
通过 capability 协商，不得互相猜测。

command 的目标生命周期是：

```text
requested → accepted → progress* → completed
                         ├────────→ failed
                         └────────→ cancelled
```

`approval.request` 或 `clarify.request` 未完成时，命令不得被客户端推断为已完成。
当前 Hermes 适配器只把基线 `message.send` 交给 Hermes handler；command、审批和
澄清事件尚未接入业务处理。客户端收到未支持事件时必须走 fallback，而不是把它
当作普通文本成功回复。

## v0.11 artifact

当前已实现的是 Orialis Server 附件资源：先走
`POST /api/v1/conversations/{conversation_id}/attachments`，消息和 Gateway 基线帧只带
`id`、名称、MIME、大小和 `download_url`。结构化 `artifact` / `artifact.event` 帧
使用 `artifact_id`、`conversation_id`、`name`、`mime_type`，并至少提供 `url`、
`download_url` 或 `content`；服务端生命周期事件则使用 `artifact` object：

```json
{
  "id": "art_001",
  "kind": "document",
  "name": "Orialis-report.pdf",
  "mime_type": "application/pdf",
  "size": 48231,
  "uri": "https://orialis.example/api/v1/attachments/art_001/download"
}
```

`artifact.started`（兼容别名 `artifact.created`）表示开始登记，`artifact.completed`
表示产物元数据可用，`artifact.failed` 必须带 `code` 和 `message`。Voice/audio/video
artifact 在 v0.10 已明确排除，不因 v0.11 重新开放。

## v0.12 capabilities 与 fallback

Agent Gateway 的能力恢复使用 `capabilities.hello` / `capabilities.ack`，而
`GET /api/v1/capabilities` 是 HTTP API 类别查询，二者不要混用。Agent 握手示例：

```json
{
  "version": 1,
  "type": "capabilities.hello",
  "capabilities": ["agent.delta", "clarify.request", "artifact.completed"],
  "resume_from": 12
}
```

Orialis 返回 `capabilities.ack`，携带服务端 capability 名称、实际采用的
`resume_from` 和下一条服务端事件序列：

```json
{
  "version": 1,
  "type": "capabilities.ack",
  "capabilities": ["agent.delta", "clarify.request", "artifact.completed"],
  "resume_from": 12,
  "next_seq": 13
}
```

当前服务端 capability 列表见 Rust `SERVER_CAPABILITIES`，只包含已接入传输层的
`agent.*`、`tool.*`、`clarify.*`、`approval.*`、`session.*` 和 `artifact.*`。它不
宣称 `command.*`、`cron.*`、`voice`。HTTP `/api/v1/capabilities` 当前返回
`messages`、`attachments`、`incremental-sync`、`websocket` 等 API 类别；客户端
必须忽略未来新增响应字段，并按实际 capability 声明启用扩展。fallback 规则如下：

1. 能力查询失败：只使用 v1 基线消息、HTTP Session、HTTP 增量同步和已知附件类型；
   不发送扩展事件。
2. 服务端返回 `UNKNOWN_TYPE` 或不支持某个 `type`：保留原请求/事件 ID，改用
   `message.send` 的纯文本摘要，或显示“需要升级 Orialis 客户端”；不得伪造成功。
3. 客户端不支持附件：发送文本中的文件名和 Orialis 下载提示，仍保留原附件 ID；
   不把二进制塞进 WebSocket。
4. Agent 离线或超时：Orialis Server 保留投递队列并退避重试；客户端显示等待状态，
   不重复创建用户消息。客户端重连后仍使用原 `message_id`。
5. `seq` 出现 gap：按 `expected_seq` 补发/重连并使用 `capabilities.hello.resume_from`；
   HTTP `cursor` 无法继续则切换到 snapshot，snapshot 完成前不推进本地游标。

## 客户端兼容矩阵

| 客户端 | 基线 | 可用扩展 | 遇到未知扩展 |
| --- | --- | --- | --- |
| Orialis Android v1 | HTTP Session、mobile envelope、sync cursor、文本/附件消息 | 以 `/api/v1/capabilities` 为准 | 忽略未知 mobile payload，重新拉取 HTTP 状态 |
| Hermes Orialis v0.2 | 8 类基线 Agent 帧、文本和非语音附件、ACK、重连 | 尚未接入结构化事件业务 handler | `error` 后回到文本消息或等待升级 |
| Orialis macOS Hermes v1.x | 与 Windows 相同的 Agent v1 基线 | 仅使用双方都声明的事件和 artifact | 保留 ID，按 fallback 发送纯文本 |
| Orialis Windows Hermes v1.x | 与 macOS 相同；附件文件名按安全显示名处理 | 仅使用双方都声明的事件和 artifact | 同上，不把路径暴露给协议 |
| 旧 HTTP-only 客户端 | Session、资源 CRUD、sync/snapshot | 无 WebSocket 扩展 | 继续轮询 HTTP，不要求 Agent Gateway |

## 配置与平台

服务端生产环境设置 `ORIALIS_AGENT_DEVICE_TOKEN`；多用户数据库另设置
`ORIALIS_AGENT_USER_ID`。Hermes 设置同一 token：

```sh
export ORIALIS_SERVER_URL='wss://orialis.jxcz.top/api/v1/agent/ws'
export ORIALIS_DEVICE_ID='JXCZ_MBA_Hermes'
export ORIALIS_DEVICE_TOKEN='在运行环境注入，不要提交'
```

Windows PowerShell：

```powershell
$env:ORIALIS_SERVER_URL = 'wss://orialis.jxcz.top/api/v1/agent/ws'
$env:ORIALIS_DEVICE_ID = 'JXCZ_WIN_Hermes'
$env:ORIALIS_DEVICE_TOKEN = '在运行环境注入，不要提交'
```

macOS 与 Windows 使用相同字段和协议；只允许平台值分别为 `macos`、`windows`。
本地无 TLS 使用 `ws://`，生产使用 `wss://`。token 不得提交、写入日志或放入
`download_url`；附件路径只在插件本地临时使用，不能由远程文件名穿越目录。

## 明确非目标：v0.10 Voice

v0.10 Voice 是**未实现且有意排除**的协议范围。Orialis 当前不定义语音录音、
语音转写、音频流、音频附件、视频附件或语音事件；任何此类 MIME 都应被拒绝或由
客户端 fallback 为文本。不要通过增加一个未注册的 `voice.*` 类型绕过此约束。

## 参考样例

当前基线样例在本目录 `examples/`：`hello.json`、`hello_ack.json`、`ping.json`、
`pong.json`、`message_send.json`、`message_ack.json`、`message_reply.json` 和
`error.json`。结构化事件和扩展样例包括 `capabilities_hello.json`、
`clarify_requested.json`、`approval_requested.json`、`session_start.json`、
`command_request.json`、`cron_delivery.json`、`artifact_completed.json` 和
`generic_artifact_ready.json`；其中
`command_request.json` / `cron_delivery.json` 在当前 Rust Gateway 仍是兼容设计样例。
所有示例使用规范名称 Orialis，不包含真实 token。
