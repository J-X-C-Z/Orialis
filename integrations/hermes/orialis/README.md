# Orialis Hermes 集成（v1.0，非语音）

这是 Hermes 与 Orialis Server Agent Gateway 之间的桥接插件。Hermes 继续负责 Agent 执行；插件负责 WebSocket 会话、消息确认、重连、能力协商、结构化 Agent 事件，以及受支持附件的下载和上传。

## 支持范围

- Agent Gateway 协议版本 `1`：基础消息、能力协商、带序列 Agent/工具/澄清/审批/会话/产物事件，以及可恢复错误。
- Orialis → Hermes：文本消息，以及图片、文本、文档和源文件附件。
- Hermes → Orialis：文本回复，以及通过 Server HTTP 文件 API 上传的图片或文档附件。
- 多 Agent 设备：每个 Hermes 安装使用独立、稳定的设备 ID；服务端可将账号消息路由到当前选中的在线设备。
- 协议错误会生成 `error` 帧；未知类型或格式错误不应使插件进程退出。

附件内容不走 WebSocket。消息中只传附件元数据，实际字节通过 Orialis Server 的 HTTP API 传输。

插件当前版本提供 Orialis Agent Gateway v1 的非语音适配：结构化事件按 Hermes
平台回调映射，澄清/审批使用 Hermes 原生 resolver，命令、会话和主动投递保留
request/delivery ID 并按能力协商执行。调度触发仍由 Hermes Cron 负责；服务端不
自行伪造 Agent 内部状态。插件收到未支持的结构化事件或类型时必须保留关联 ID、
返回可恢复错误或降级为纯文本，不得报告伪造的完成状态。

## 配置

在 Hermes 的 Orialis 平台配置中设置以下环境变量（或对应的 platform `extra` 配置）：

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `ORIALIS_SERVER_URL` | 是 | Agent Gateway WebSocket URL，例如 `ws://127.0.0.1:18443/api/v1/agent/ws`。附件 HTTP 地址从同一服务派生。 |
| `ORIALIS_DEVICE_ID` | 是 | 稳定设备 ID，格式为 `<USER>_<DEVICE>_<Agent>`，例如 `JXCZ_MBA_Hermes`。每段仅允许 ASCII 字母或数字，长度为 2–24；总长度不超过 80。 |
| `ORIALIS_DEVICE_TOKEN` | 条件 | 当服务端设置了 `ORIALIS_AGENT_DEVICE_TOKEN` 时必须设置，并与其完全相同。 |

生产环境请启用并配置设备 token。插件通过 `Authorization: Bearer <device-token>` 认证；不要将 token 提交到仓库或写入日志。开发模式下，仅当服务端 token 未设置时，允许本机未认证连接。

## macOS / Windows

两平台配置项和协议完全相同。分别在运行 Hermes 的进程环境中设置变量，然后重启或重新加载 Hermes 插件：

macOS（shell）：

```sh
export ORIALIS_SERVER_URL='ws://127.0.0.1:18443/api/v1/agent/ws'
export ORIALIS_DEVICE_ID='JXCZ_MBA_Hermes'
export ORIALIS_DEVICE_TOKEN='替换为服务端设备 token'
```

Windows PowerShell：

```powershell
$env:ORIALIS_SERVER_URL = 'ws://127.0.0.1:18443/api/v1/agent/ws'
$env:ORIALIS_DEVICE_ID = 'JXCZ_WIN_Hermes'
$env:ORIALIS_DEVICE_TOKEN = '替换为服务端设备 token'
```

本地服务使用 `ws://`；启用 TLS 的服务使用 `wss://`。Windows 的路径会被插件转换为安全的文件名，不能通过附件名称写入任意目录；macOS 同样适用。

## 协议字段

所有帧都必须包含 `version: 1` 和字符串 `type`。`hello` 由插件发送，字段为：

```json
{
  "version": 1,
  "type": "hello",
  "device_id": "JXCZ_MBA_Hermes",
  "client": "orialis-hermes-plugin",
  "plugin_version": "1.0.0",
  "platform": "macos",
  "capabilities": ["messages", "attachments", "agent.delta", "tool.started", "clarify.request", "approval.request", "session.start", "artifact.completed"]
}
```

`platform` 按运行系统报告为 `macos` 或 `windows`。业务消息字段如下：

- `message.send`：`message_id`、`conversation_id`、`content`，可选 `attachments`。
- `message.ack`：`message_id`、`status`。它只表示已收到，不表示 Hermes 已处理完成。
- `message.reply`：`message_id`、`reply_to`、`conversation_id`、`content`，可选 `attachments`。
- `error`：`code`、`message`，可选 `reply_to`。

每个附件是元数据对象：`id`、`name`、`mime_type`、`download_url` 必填，`size` 可选且必须为正整数。示例：

```json
{
  "id": "att_001",
  "name": "report.pdf",
  "mime_type": "application/pdf",
  "size": 48231,
  "download_url": "https://server.example/api/v1/attachments/att_001/download"
}
```

允许的 MIME 类型包括 `image/*`、`text/*`、`application/pdf`、`application/json`、`application/xml` 和 `application/octet-stream`。单条消息最多 16 个附件，名称最多 180 个字符。

## 限制

- 不支持语音、音频或视频附件（包括 `audio/*`、`video/*`）。它们不会通过 WebSocket 或 HTTP 文件 API 桥接。
- 单个附件必须大于 0 且不超过 20 MiB；下载和上传分别有 15 秒和 30 秒超时。
- 下载 URL 必须属于配置的 Orialis Server；响应 MIME 必须与元数据匹配。临时下载文件只在本次处理期间存在。
- WebSocket 只承载 JSON 文本帧，不承载附件字节。
- 连接断开后插件自动重连，延迟从 1 秒逐步增加至最多 30 秒。
- v0.10 Voice 是未实现且有意排除的范围：语音、音频、视频和任何 `voice.*` 事件
  不会通过本插件、Orialis Agent Gateway 或 HTTP 附件 API 传输。

## 兼容与 fallback

| 对端 | 插件可依赖 | 插件行为 |
| --- | --- | --- |
| Orialis Server v1 基线 | 8 类基础帧、`message_id` 去重、`reply_to` 关联、ACK、重连 | 正常处理文本和非语音附件 |
| Orialis Server v0.3–v0.12 扩展 | 只有 `/api/v1/capabilities` 明确声明的事件 | 未声明事件不执行，回到文本或返回未支持错误 |
| 旧 HTTP-only 客户端 | 无 Agent WebSocket | 继续保留消息在 Orialis Server 的投递队列 |

若能力查询失败，插件只使用当前基线。若 Orialis Server 暂时离线，服务端会保留
手机消息并退避重试；插件重连后继续使用原 `message_id`，不能创建第二条用户消息。
`message.ack` 只确认收到，不等于回复完成。

Session 也分两种：插件使用 WebSocket 握手中的设备 token；Orialis 手机/HTTP
客户端使用 `Authorization: Session <accessToken>`。两者不能互换，Agent 事件中
未来的 `session_id` 也不是 access token。

## 故障排查

**无法连接**

确认 URL 使用正确的 `/api/v1/agent/ws` 路径、服务端正在运行且网络可达；本地无 TLS 用 `ws://`，TLS 用 `wss://`。确认 `websockets` 依赖已安装。

**认证失败**

检查服务端的 `ORIALIS_AGENT_DEVICE_TOKEN` 与客户端 `ORIALIS_DEVICE_TOKEN` 是否完全一致，并确认 token 没有被额外引号或空格包裹。不要把 token 发到聊天或日志中。

**设备在线但收不到移动端消息**

检查 `ORIALIS_DEVICE_ID` 是否唯一且符合三段格式。多用户数据库还需要在服务端设置 `ORIALIS_AGENT_USER_ID`；随后通过 `GET /api/v1/agent/devices` 查看设备，并用 `POST /api/v1/agent/devices/{device_id}/select` 选择目标设备。

**附件被拒绝或没有出现在回复中**

检查 MIME 类型、文件大小（≤20 MiB）、附件数量（≤16）和文件名长度。确认 `download_url` 与 `ORIALIS_SERVER_URL` 指向同一服务，并检查服务端 HTTP 文件 API 是否可访问。语音、音频、视频不会被桥接。

**消息重复或状态不确定**

`message.ack` 只确认接收；断线重连期间应以 `message_id` 和 `reply_to` 关联消息。若收到 `error` 帧，先记录其 `code` 和 `message`（不要记录 token），再修正对应字段或协议版本。
