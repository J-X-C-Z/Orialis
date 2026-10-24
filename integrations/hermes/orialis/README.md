# Orialis Hermes 集成（v1.0，非语音）

这是 Hermes 与 Orialis Server Agent Gateway 之间的桥接插件。Hermes 继续负责 Agent 执行；插件负责 WebSocket 会话、消息确认、重连、能力协商、结构化 Agent 事件，以及受支持附件的下载和上传。

## 支持范围

- Agent Gateway 协议版本 `1`：基础消息、能力协商、带序列 Agent/工具/澄清/审批/会话/产物事件，以及可恢复错误。
- Orialis → Hermes：文本消息，以及图片、文本、文档和源文件附件。
- Hermes → Orialis：文本回复，以及通过 Server HTTP 文件 API 上传的图片或文档附件。
- 首回应与正文并行：协商 `reply_followups` 的服务端上，普通用户消息开始处理时，在后台使用 `orialis_initial_response` 辅助模型按本次内容生成一两句自然回应，Hermes 同时开始主处理，不等待该模型或首回应 ACK。当前部署沿用 Westlake DeepSeek 非思考模式（Qwen 后备）、正文默认低档思考。辅助调用在线程中执行，预算 12 秒；失败或返回思考内容时使用备用短句。正文、原生中间消息或常规回复先到时，取消尚未发出的首回应，优先发送实际内容；不会为保证开场白出现而拖慢完整回复。已生成首回应的内容沿用既有私有附件缓存与确定性 `initial_` ID，重试或重启保持稳定。命令、后台任务和旧版服务端不插入首回应。
- 中途进度汇报：保留 Hermes 原生 `Commentary`，并在长时间没有公开输出时，由独立后台摘要结合本轮用户请求、真实阶段变化、主模型已经公开说明的进展和之前的汇报，自然概括当前正在处理的具体对象或目标。摘要复用已配置的非思考辅助路由，调用等待预算 12 秒、相邻尝试至少间隔 30 秒，每轮至多一个摘要生成协程；同一进度成功汇报后不重复。不会读取工具参数、原始输出或隐藏思考，也不把“工具调用返回”当作成功。生成失败、空内容、含思考内容或已过时就跳过，不发送固定模板占位句。主处理不等待摘要生成或其 ACK；正文输出时暂停并取消待发摘要，新工具阶段才可恢复，最终回复优先。已生成摘要沿用私有缓存，`progress_` ID 由用户 anchor 与消息文本确定；完成、停止、真实断线或新轮开始时关闭旧轮更新，避免迟到。此行为取代 TASK-021 的固定本地状态短句及其零额外进度 LLM 请求约束，不调整主模型或正文思考档位。
- 多 Agent 设备：每个 Hermes 安装使用独立、稳定的设备 ID；服务端可将账号消息路由到当前选中的在线设备。
- 屏幕记忆：协商 `memory.analyze` 后，以独立 `memory.analyze` / `memory.result` 后台请求处理内容。使用 Hermes 的 `vision` 辅助模型配置，无聊天会话或聊天消息；支持不超过 900 KiB 的 JPEG 截图、100000 UTF-8 字节文本和最多 32 个原始来源链接。模型按结构化结果返回 `category: ai|other`。
- 视频理解：当前支持哔哩哔哩公开视频，先读取平台字幕，没有可读字幕时使用故事板抽样 JPEG 画面。字幕时间必须与原视频分段时长匹配；出现负值、非有限值、倒序区间或超过舍入容差时弃用整条轨道，改用抽样画面；字幕仅含音乐标记时也改用画面。保留原始完整链接（含签名和 `p` 分段参数），优先核验原始链接或截图中清晰完整的 BV 编号。两者都没有时，AI只抄录同一B站视频的可见标题和UP主，由后台执行WBI视频搜索；仅采用唯一同时匹配的候选，并再次核验视频详情的标题与UP主。标题明显截断时只允许足够长的可见前缀匹配，不按相似度猜测。找不到或存在多个候选时保留截图并提示分享原链接，不生成猜测的BV号。字幕或画面均不可用时，`video_status: unavailable`，保留截图摘要与可重试原因。其他视频平台保留原始链接并明确暂不支持内容理解。故事板抽样不等于完整观看，也不包含未提供的音频理解。
- 视频 HTTP 只读取固定哔哩哔哩 API、来源及 CDN 域名；每个重定向均验证目标，连接到已核验的公共 IP，限制读取时长和大小。仅读取用户专门授权的服务器凭据文件，不导入其他应用的登录态、不下载完整视频、不执行 ASR。整个后台请求最多等待 285 秒，断线取消等待；服务端保留失败状态供重试。

### 可选的服务器 B站扫码授权

匿名请求持续返回412时，可按参考项目使用正常B站扫码登录。登录工具只在显式运行时启动，手机端代码和安装包不需要修改；账号会话只写到服务器的专用文件，不导入其他应用的Cookie。

在隔离的 `bilibili-api-python==17.4.1` 环境运行：

```sh
<isolated-sdk-python> bili_login.py \
  --credential-file /home/hermes/.hermes/orialis-memory/bili_credential.json \
  --qr-file /home/hermes/.hermes/orialis-memory/login.png \
  --timeout 180
```

用户在B站App扫码确认后，工具原子写入权限600的凭据文件。读取默认位置为 `$HERMES_HOME/orialis-memory/bili_credential.json`（未设置HERMES_HOME时使用 `~/.hermes`）；也可显式设置 `ORIALIS_BILI_CREDENTIAL_FILE` 绝对路径。登录Cookie只发送给B站域名，不发给短链或图床。默认文件缺失时保留匿名行为；显式指定的文件缺失或不可读时返回可处理的授权错误；无B站来源的普通截图整理不读取该文件。登录态是否能解决特定出口的限制，必须在授权后通过真实视频获取和模型结果验收。

### 视频理解依赖

使用 Hermes 已安装的 `agent.auxiliary_client.async_call_llm` 和 `vision` 辅助模型配置；
故事板裁图需要 **Pillow**（本次本机验收为 12.3.0）。部署到新的 Hermes 环境前运行：

```sh
/path/to/hermes/venv/bin/python -c 'from PIL import Image; from agent.auxiliary_client import async_call_llm'
```

若缺少 Pillow，在该环境安装 `Pillow>=10`；没有该依赖时不会将标题当作视频内容，
字幕仍可使用，故事板读取会返回可重试的未完成状态。参考实现及许可证见
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)。
- 聊天创建日程：Hermes 提供 `create_schedule`，接收标题、RFC 3339 起止时间，以及可选描述、地点、全天、重要程度和提醒设置。插件通过配置的 Agent Bearer token 调用 `/api/v1/schedules`；服务端将新日程写入既有同步流。
- 资讯发布：Hermes 注册单一 `news.publish` 工具，通过受限 dataset 枚举发布 AIHOT 热点/条目/事件/报告、GitHub 每周或每日榜单，以及 Orialis 项目报告。插件只将 dataset 映射到固定 REST 路由；source、taskId 和 idempotencyKey 由插件生成，调用方不能提供 URL、路径、用户 ID 或任务 ID。项目报告可选传入 `projectId`，服务端仍会验证该项目归属。
- 用户域 HTTP 工具：插件提供经过显式输入校验、全部使用 `Authorization: Bearer $ORIALIS_DEVICE_TOKEN` 的异步工具，覆盖任务 CRUD、项目 CRUD/summary、里程碑 CRUD、`/schedules` 与 `/calendar-events` CRUD、会话 CRUD，以及会话消息的 list/create。PATCH 和 DELETE 始终要求 `baseVersion`；消息附件仍由既有 adapter/HTTP 附件 API 处理。
- 协议错误会生成 `error` 帧；未知类型或格式错误不应使插件进程退出。

附件内容不走 WebSocket。消息中只传附件元数据，实际字节通过 Orialis Server 的 HTTP API 传输。

插件当前版本提供 Orialis Agent Gateway v1 的非语音适配：结构化事件按 Hermes
平台回调映射，澄清/审批使用 Hermes 原生 resolver，命令、会话和主动投递保留
request/delivery ID 并按能力协商执行。调度触发仍由 Hermes Cron 负责；服务端不
自行伪造 Agent 内部状态。插件收到未支持的结构化事件或类型时必须保留关联 ID、
返回可恢复错误或降级为纯文本，不得报告伪造的完成状态。

## 配置

手机工作区（目录、文本预览、上传下载、Git diff、可选交互终端）的配置与线协议见
[`workspace-v1.md`](../../../protocol/agent-gateway/workspace-v1.md)。默认不共享任何目录。
通过 `ORIALIS_WORKSPACES` 或平台 `extra.workspaces` 显式配置允许目录；终端还需
逐目录设置 `terminal:true`。终端具有 Hermes 进程用户的系统权限，所选目录仅是
初始工作目录，不构成终端命令的文件系统沙箱。

在 Hermes 的 Orialis 平台配置中设置以下环境变量（或对应的 platform `extra` 配置）。要从聊天创建日程，必须配置 Agent token：

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `ORIALIS_SERVER_URL` | 是 | Agent Gateway WebSocket URL，例如 `ws://127.0.0.1:18443/api/v1/agent/ws`。附件 HTTP 地址从同一服务派生。 |
| `ORIALIS_DEVICE_ID` | 是 | 稳定设备 ID，格式为 `<USER>_<DEVICE>_<Agent>`，例如 `JXCZ_MBA_Hermes`。每段仅允许 ASCII 字母或数字，长度为 2–24；总长度不超过 80。 |
| `ORIALIS_ALLOWED_USERS` | 聊天授权必需 | 设置为该网关自己的 `ORIALIS_DEVICE_ID`（例如 `JXCZ_MBA_Hermes`）。插件把已通过服务端鉴权的入站消息映射为此发送者；Hermes 默认拒绝未授权发送者。不要用全局 allow-all 替代。 |
| `ORIALIS_DEVICE_TOKEN` | 用户域工具必需 | 必须与服务端 `ORIALIS_AGENT_DEVICE_TOKEN` 一致，由服务端绑定用户；Gateway 启用 Agent 认证时也必须配置。 |
| `ORIALIS_NEWS_PUBLISHER_TOKEN` | 发布资讯必需 | 单独的资讯发布 Bearer secret；不能用 `ORIALIS_DEVICE_TOKEN` 代替。必须与 Orialis 服务端配置的 `ORIALIS_NEWS_PUBLISHER_TOKEN` 一致。 |

服务端还必须设置 `ORIALIS_NEWS_PUBLISHER_USER_ID`，将 publisher token 绑定到一个已存在的 Orialis 用户。资讯会发布到该用户名下；客户端不能覆盖该绑定。项目报告带有 `projectId` 时，服务端会再检查项目是否属于这个用户。不要将 publisher secret 提交到仓库或写入日志。

仓库级静态/协议门禁可运行 `python scripts/validate-contracts.py`。若要运行
依赖 Hermes `gateway` 包的完整插件测试，使用 Hermes 虚拟环境：

```sh
HERMES_PYTHON=/path/to/hermes/venv/bin/python scripts/validate-hermes-plugin.sh
```

生产环境请启用并配置设备 token。插件通过 `Authorization: Bearer <device-token>` 认证；不要将 token 提交到仓库或写入日志。开发模式下，仅当服务端 token 未设置时，允许本机未认证连接。

完整用户域工具需在 Hermes `platform_toolsets` 中为 `orialis` 启用
`[hermes-cli, orialis]`，并将 `ORIALIS_ALLOWED_USERS` 精确设为当前设备 ID。
接收手机附件时，`ORIALIS_SERVER_URL` 应与服务端生成的附件链接使用同一来源
（例如 `wss://orialis.jxcz.top/api/v1/agent/ws` 对应 HTTPS 下载链接）；
不要通过关闭来源检查解决公网链接与 loopback 网关地址不一致的问题。
Schedule 单条读取通过既有集合分页查找，服务端没有单条 GET 路由。

## macOS / Windows

两平台配置项和协议完全相同。分别在运行 Hermes 的进程环境中设置变量，然后重启或重新加载 Hermes 插件：

macOS（shell）：

```sh
export ORIALIS_SERVER_URL='ws://127.0.0.1:18443/api/v1/agent/ws'
export ORIALIS_DEVICE_ID='JXCZ_MBA_Hermes'
export ORIALIS_ALLOWED_USERS='JXCZ_MBA_Hermes'
export ORIALIS_DEVICE_TOKEN='替换为服务端设备 token'
export ORIALIS_NEWS_PUBLISHER_TOKEN='替换为服务端资讯 publisher token'
```

Windows PowerShell：

```powershell
$env:ORIALIS_SERVER_URL = 'ws://127.0.0.1:18443/api/v1/agent/ws'
$env:ORIALIS_DEVICE_ID = 'JXCZ_PC_Hermes'
$env:ORIALIS_ALLOWED_USERS = 'JXCZ_PC_Hermes'
$env:ORIALIS_DEVICE_TOKEN = '替换为服务端设备 token'
$env:ORIALIS_NEWS_PUBLISHER_TOKEN = '替换为服务端资讯 publisher token'
```

Orialis 移动端聊天设备列表默认将 `JXCZ_PC_Hermes` 作为 Windows 目标。Windows Hermes 以此 ID 连接并在线后，可从移动端新建绑定到该设备的聊天；发送内容经 Orialis Gateway 转发，回复回到同一会话。若更换设备 ID，移动端构建时设置 `ORIALIS_WINDOWS_CHAT_DEVICE_ID` 为相同值。

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
- WebSocket 承载 JSON 文本帧；聊天附件仍通过 HTTP 上传下载，屏幕记忆的压缩 JPEG 在独立后台请求中以 Base64 传输。
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

**设备在线但不回复，日志出现 Unauthorized user**

在该 Hermes profile 的 `.env` 设置 `ORIALIS_ALLOWED_USERS` 为该网关自己的 `ORIALIS_DEVICE_ID`，仅重启该 profile 网关。已有连接不能证明发送者授权通过；应核对入站消息、`message.reply` 发送和服务端回复落盘。

**设备在线但收不到移动端消息**

检查 `ORIALIS_DEVICE_ID` 是否唯一且符合三段格式。多用户数据库还需要在服务端设置 `ORIALIS_AGENT_USER_ID`；随后通过 `GET /api/v1/agent/devices` 查看设备，并用 `POST /api/v1/agent/devices/{device_id}/select` 选择目标设备。

**附件被拒绝或没有出现在回复中**

检查 MIME 类型、文件大小（≤20 MiB）、附件数量（≤16）和文件名长度。确认 `download_url` 与 `ORIALIS_SERVER_URL` 指向同一服务，并检查服务端 HTTP 文件 API 是否可访问。语音、音频、视频不会被桥接。

**消息重复或状态不确定**

`message.ack` 只确认接收；断线重连期间应以 `message_id` 和 `reply_to` 关联消息。若收到 `error` 帧，先记录其 `code` 和 `message`（不要记录 token），再修正对应字段或协议版本。
# Test layers

The plugin checks are intentionally split into three layers:

1. `validate-contracts.py` validates every shared contract fixture against its schema and checks cross-message semantics.
2. Python byte-compilation catches import-time syntax errors without requiring Hermes.
3. The public CI job runs the Hermes-independent protocol and tool tests. When the
   Hermes runtime is present, it additionally runs `unittest discover` over every
   `test_*.py` module under this plugin.

Local Hermes-runtime validation is an optional fourth layer using `scripts/validate-hermes-plugin.sh`; it validates the manifest and repeats full discovery with the Hermes Python runtime.

The plugin test dependencies are listed in `tests/requirements.txt` (`pytest`,
`jsonschema`, and the storyboard crop dependency Pillow). Install them into an
isolated test environment or a temporary `--target` directory, and include that
directory in `PYTHONPATH` when running full discovery. The contract fixture module
also uses pytest parametrization; run it with `python -m pytest` to execute its
12 schema cases rather than only importing it through unittest discovery.

## 批量创建

`create_schedules`（日程）、`create_tasks`（任务）、`create_projects`、
`create_milestones`、`create_conversations`、`create_messages` 支持
`{"items": [...]}`，每批 1–200 条；兼容入口 `create_calendar_events` 同样可用。
每项字段与对应单条创建工具一致，里程碑每项含 `projectId`，消息每项含
`conversationId`。整学期课表可用一次 `create_schedules` 调用录入。

插件先完成整批本地结构和日程时间校验；发现坏项返回 `validationIndex`
（从 0 开始）和 `written: 0`，不会发出写入请求。服务器仍负责账号、
关联资源、日期等最终校验。随后按输入顺序调用现有 HTTP 接口，不是事务，
一项失败后继续后续项。响应含 `atomic: false`、`total`、`succeeded`、
`failed` 和逐项 `results`；每项包含 `index`、`submitted`、`ok` 和结果或错误。
`succeeded` 是成功响应数（服务端可能返回已有 ID），不代表全为新增。

除里程碑外，缺失 ID 会在请求前生成，并放入 `submitted` 供核对。
同批重复 ID 在写入前拒绝。插件不自动重试；网络中断、服务端 5xx 或
不可解析的写入响应标记 `outcomeUnknown: true`，需先读取核对是否已写入，
再决定是否重试。禁止直接重放整批；里程碑由服务端生成 ID，尤其需要先核对。
批量上限不改变服务器每项目最多 100 个里程碑的限制。

```json
{
  "items": [
    {"title": "高等数学", "startAt": "2026-10-05T08:00:00+08:00", "endAt": "2026-10-05T09:35:00+08:00", "location": "教学楼 201"},
    {"title": "大学英语", "startAt": "2026-10-05T10:00:00+08:00", "endAt": "2026-10-05T11:35:00+08:00"}
  ]
}
```

### 附件缓存

下载的附件保存在当前 Hermes profile 的 `HERMES_HOME/cache/orialis-attachments/`，
按服务、设备和凭据指纹隔离。回复结束、断连和网关重启不删除已下载文件，
后续对话可继续读取原路径；同名附件有独立路径。默认保留收件或本轮处理结束后的
30 天，在下次接收附件时清理过期且未在处理中的目录。模型直接读取文件不延长
该期限。下载失败的半成品会删除，完整文件可在重试或重启后复用。
