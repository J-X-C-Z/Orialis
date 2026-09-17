# Orialis API v1

本文档定义 Orialis 当前服务端已经提供的 API，以及下一步建议实现的同步能力。

本文档以 `orialis-server/src/main.rs`、`orialis-core/src/lib.rs` 和
`orialis-server/migrations/` 的当前工作树为准。标记为“建议”的内容仍属于后续
设计，其余接口可作为已完成基础实现的契约使用。

三端（手机版、Rust 服务端、Hermes 插件）的字段、兼容策略和验收边界见
[`docs/server-plugin-mobile-alignment.md`](server-plugin-mobile-alignment.md)。

Agent Gateway 的非语音事件扩展（v0.3–v0.12 / v1.x）另有完整字段表和 JSON
Schema，见 [`protocol/agent-gateway/README.md`](../protocol/agent-gateway/README.md)
及 [`event-v1.schema.json`](../protocol/agent-gateway/schema/event-v1.schema.json)。
本 API 文档只把已存在的 HTTP/mobile 行为标为“已实现”，不把后续事件名当作现有
路由。

## 1. 基本约定

- 正式 API 前缀为 `/api/v1`。
- `GET /api/health` 是兼容入口；正式健康检查是 `GET /api/v1/health`。
- 请求和响应使用 JSON，字段统一使用 `camelCase`。
- 服务端默认生成实体 ID，当前为 UUID 字符串；本地优先客户端同步创建时也可
  提交自己的本地 ID，服务端会原样保留，客户端仍应将 ID 视为不透明值。
- 时间戳使用 RFC 3339 字符串，服务端当前生成 UTC 时间，例如
  `2026-09-16T08:00:00Z`。
- 日期字段使用 `YYYY-MM-DD`，时间字段使用 `HH:mm`。
- 实体版本从 `1` 开始，每次更新或软删除递增。
- 所有业务数据按当前 Session 的用户隔离；接口不会接受客户端传入的
  `userId` 作为归属依据。

### 1.1 认证

除注册、登录、健康检查、元数据和能力查询外，接口需要 Session 认证：

```http
Authorization: Session <accessToken>
```

当前 Session 查询也接受名为 `orialis_session` 的 Cookie：

```http
Cookie: orialis_session=<accessToken>
```

但当前登录、注册不会自动设置 Cookie，客户端应保存响应中的
`accessToken` 并通过 `Authorization` 头发送。当前注销接口只接受
`Authorization` 头。

### 1.2 协议路线图与实现边界

| 版本 | 非语音协议主题 | 当前状态 |
| --- | --- | --- |
| v0.3 | Agent 扁平事件帧：`event_id`、`seq`、`session_id` 和类型字段 | Rust parser、Hermes 事件映射和移动端时间线已实现 |
| v0.4 | `Idempotency-Key`、请求关联、设备级序列和重放 | HTTP mutation/sync、Agent 去重/gap/resume 已实现 |
| v0.5 | `clarify.request` / `clarify.response` / `clarify.cancel` | Rust/Python 校验、Hermes resolver 和移动交互已实现 |
| v0.6 | `approval.request` / `approval.resolve` | Rust 去重、超时、ACK、Hermes resolver 和移动交互已实现 |
| v0.7 | `session.*` 生命周期与 session 请求 | 传输类型已实现；HTTP access Session 独立实现 |
| v0.8 | `command.request` / `command.reply`、工具状态 | 工具事件已实现；移动端命令通过 Gateway 消息语义桥接 |
| v0.9 | cron 调度与运行记录 | 未实现；`recurrence` 不会触发后台任务 |
| v0.10 | Voice | **未实现且有意排除** |
| v0.11 | artifact 产物事件 | Rust/Python 校验、Hermes 产物映射、移动展示与附件 HTTP API 已实现 |
| v0.12 / v1.x | capabilities、fallback、兼容冻结 | HTTP capabilities 与 Agent resume 已实现 |

因此，当前客户端可以依赖基础 Agent 帧以及双方通过 capabilities 协商的非语音
结构化事件。遇到未声明的扩展必须 fallback 为文本或回到 HTTP 状态恢复；不能推断
为成功。

## 2. 当前接口总览

| 方法 | 路径 | 认证 | 状态 | 说明 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/health` | 否 | 已实现 | 服务健康状态 |
| GET | `/api/v1/meta` | 否 | 已实现 | 服务元数据 |
| GET | `/api/v1/capabilities` | 否 | 已实现 | 当前能力列表 |
| POST | `/api/v1/auth/register` | 否 | 已实现 | 注册并创建 Session |
| POST | `/api/v1/auth/login` | 否 | 已实现 | 登录并创建 Session |
| POST | `/api/v1/auth/logout` | 是 | 已实现 | 撤销当前 Session |
| GET | `/api/v1/auth/session` | 是 | 已实现 | 查询当前用户 |
| GET/POST | `/api/v1/tasks` | 是 | 已实现 | 分页查询或创建任务 |
| PATCH/DELETE | `/api/v1/tasks/{id}` | 是 | 已实现 | 更新或软删除任务 |
| GET/POST | `/api/v1/projects` | 是 | 已实现 | 查询或创建项目 |
| PATCH/DELETE | `/api/v1/projects/{id}` | 是 | 已实现 | 更新或软删除项目 |
| GET | `/api/v1/projects/{id}/summary` | 是 | 已实现 | 项目进度、完成数量和下一行动 |
| GET/POST | `/api/v1/projects/{project_id}/milestones` | 是 | 已实现 | 查询或创建项目里程碑 |
| GET/PATCH/DELETE | `/api/v1/projects/{project_id}/milestones/{id}` | 是 | 已实现 | 查询、更新或软删除里程碑 |
| GET/POST | `/api/v1/calendar-events` | 是 | 已实现 | 查询或创建日程 |
| PATCH/DELETE | `/api/v1/calendar-events/{id}` | 是 | 已实现 | 更新或软删除日程 |
| GET/POST | `/api/v1/schedules` | 是 | 已实现 | `calendar-events` 的规范名称别名 |
| PATCH/DELETE | `/api/v1/schedules/{id}` | 是 | 已实现 | Schedule 规范名称别名 |
| GET/POST/PATCH/DELETE | `/api/v1/conversations[/{id}]` | 是 | 已实现 | 会话列表、创建、重命名和删除 |
| GET/POST | `/api/v1/conversations/{conversation_id}/messages` | 是 | 已实现 | 查询或保存聊天消息；GET 支持稳定游标分页 |
| POST | `/api/v1/conversations/{conversation_id}/attachments` | Session/Agent Bearer | 已实现 | 上传聊天附件，单个文件最大 20 MB |

Conversation 的 `version` 是服务端乐观并发版本。重命名请求体为：

```json
{
  "title": "项目讨论",
  "baseVersion": 3
}
```

删除请求也必须携带同一个 `baseVersion`。成功写入后服务端版本递增；客户端的
本地连续编辑使用独立的 `localRevision`，不能把本地编辑次数写入 `version`。
网络响应丢失时可以复用原 `Idempotency-Key`；服务端已完成同一重命名时返回当前
对象，避免把一次重试误判成新的编辑。
| GET | `/api/v1/attachments/{id}/download` | Session/Agent Bearer/旧下载令牌 | 已实现 | 下载或预览聊天附件 |
| GET | `/api/v1/sync/events` | 是 | 已实现 | 按游标读取增量事件 |
| GET | `/api/v1/sync/snapshot` | 是 | 已实现 | 获取可替换本地数据的完整快照 |
| GET | `/api/v1/ws` | 是 | 已实现 | 手机端实时连接、心跳、同步提示和消息推送 |
| GET | `/api/v1/agent/devices` | 是 | 已实现 | 查询当前用户的 Hermes 设备与在线状态 |
| POST | `/api/v1/agent/devices/{device_id}/select` | 是 | 已实现 | 选择聊天消息投递设备 |

当前没有网页接口或第三方日历接口。里程碑已通过项目嵌套路由
对外提供 HTTP API。消息 POST 成功后会先持久化用户消息，再异步投递给已连接的
Hermes；收到匹配的 `message.reply` 后，服务端会保存 `role=assistant` 的消息。消息会投递到
当前用户选择的在线 Hermes 设备；选择状态保存在服务端，因此手机重启后仍然有效。

手机端首通阶段可在本地开发环境启用 `ORIALIS_DEV_DEVICE_AUTH=true`，然后使用
`X-Orialis-Device-Id` 访问需要认证的 HTTP 和 WebSocket 接口。该模式只用于本地
开发，生产环境必须保持关闭并改用正式 Session 认证；WebSocket 握手也要发送
`Authorization: Session <accessToken>`。

### 2.1 Capabilities

当前 `GET /api/v1/capabilities` 返回的结构是：

```json
{
  "service": "orialis",
  "api_version": "v1",
  "web": false,
  "capabilities": [
    "health",
    "metadata",
    "auth",
    "tasks",
    "projects",
    "calendar-events",
    "incremental-sync",
    "messages",
    "attachments",
    "agent-devices",
    "websocket"
  ]
}
```

当前响应不表示支持 `clarify`、`approval`、`command`、`cron`、通用
`artifact-events` 或 `voice`。v0.12 以后可以追加 `protocol_versions`、
`event_types` 和 `fallback`；客户端必须忽略未知响应字段，并以实际的
`capabilities` / `event_types` 声明为准。能力查询失败时只使用 v1 基线 HTTP、
mobile 和 Agent 消息契约。

## 3. 认证接口

### 3.1 注册

```http
POST /api/v1/auth/register
Content-Type: application/json
```

请求体：

```json
{
  "username": "alice",
  "password": "a-password-at-least-8-chars"
}
```

当前要求用户名长度为 3–32 个字符，密码长度为 8–128 个字符。注册成功
返回 `201 Created`，并立即创建一个有效期 30 天的 Session：

```json
{
  "userId": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f001",
  "accessToken": "<opaque-token>",
  "expiresAt": "2026-10-16T08:00:00Z"
}
```

### 3.2 登录

```http
POST /api/v1/auth/login
Content-Type: application/json
```

请求体与注册相同。成功返回 `200 OK`，响应结构与注册相同。
用户名不存在或密码错误返回 `401 Unauthorized`。

### 3.3 注销

```http
POST /api/v1/auth/logout
Authorization: Session <accessToken>
```

成功返回 `204 No Content`。服务端撤销当前令牌。

### 3.4 当前 Session

```http
GET /api/v1/auth/session
Authorization: Session <accessToken>
```

成功返回：

```json
{
  "userId": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f001",
  "username": "alice"
}
```

## 4. 任务 API

任务表示作业、长期项目中的行动项或每日任务。任务可以有截止日期和截止
时间，但不表示一个明确的工作时间段，因此不会自动写入日程。

### 4.1 任务响应对象

```json
{
  "id": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f010",
  "title": "提交作业",
  "notes": "完成实验报告并上传",
  "important": true,
  "urgent": false,
  "completed": false,
  "completedAt": null,
  "due": "2026-09-20",
  "dueTime": "23:59",
  "reminderMinutes": 30,
  "projectId": null,
  "recurrence": null,
  "createdAt": "2026-09-16T08:00:00Z",
  "updatedAt": "2026-09-16T08:00:00Z",
  "version": 1
}
```

当前响应字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 服务端生成的实体 ID |
| `title` | string | 非空标题 |
| `notes` | string/null | 备注 |
| `important` | boolean/null | 重要性；`null` 表示未分类 |
| `urgent` | boolean/null | 紧急性；`null` 表示未分类 |
| `completed` | boolean | 是否完成，创建时默认为 `false` |
| `completedAt` | string/null | 完成时间；完成任务时为 RFC 3339 时间，未完成时为 `null` |
| `due` | string/null | 截止日期 |
| `dueTime` | string/null | 截止时间；没有 `due` 时必须为空 |
| `reminderMinutes` | integer/null | 提前提醒分钟数 |
| `projectId` | string/null | 所属项目 ID |
| `recurrence` | object/null | `{"rule":"<RFC 5545 RRULE>","until":"YYYY-MM-DD"}`，或 `null` |
| `createdAt` | string | 创建时间 |
| `updatedAt` | string | 最近更新时间 |
| `version` | integer | 乐观并发版本 |

`quadrant` 不由当前服务端任务 HTTP 响应返回。领域模型中的四象限应由
`important` 和 `urgent` 派生：

| `important` | `urgent` | 四象限 |
| --- | --- | --- |
| true | true | `q1` |
| true | false | `q2` |
| false | true | `q3` |
| false | false | `q4` |

### 4.2 查询任务

```http
GET /api/v1/tasks?limit=50&after=<opaque-cursor>
Authorization: Session <accessToken>
```

返回当前用户未删除任务的一页，默认 `limit=50`，允许范围为 `1–100`。
服务端按截止日期、截止时间、创建时间和实体 ID 稳定排序；没有截止日期或
截止时间的任务排在有值任务之后。

响应结构：

```json
{
  "items": [],
  "nextCursor": "<opaque-cursor>",
  "hasMore": true
}
```

首次请求省略 `after`；后续请求原样携带上一页的 `nextCursor`。最后一页的
`nextCursor` 为 `null`。游标由服务端生成，格式无须客户端解析；非法游标或
超出范围的 `limit` 返回 `400`。当前仍无任务筛选或单任务 `GET` 接口。

### 4.3 创建任务

```http
POST /api/v1/tasks
Authorization: Session <accessToken>
Content-Type: application/json
```

请求体：

```json
{
  "title": "提交作业",
  "notes": "完成实验报告并上传",
  "important": true,
  "urgent": false,
  "completed": false,
  "completedAt": null,
  "due": "2026-09-20",
  "dueTime": "23:59",
  "reminderMinutes": 30,
  "projectId": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f020",
  "recurrence": { "frequency": "daily" }
}
```

成功返回 `201 Created` 和任务对象。`title` 为空或只有空白字符返回
`400 Bad Request`；只提供 `dueTime` 而没有 `due` 也返回 `400`。`due` 使用
`YYYY-MM-DD`，`dueTime` 使用本地时间 `HH:MM`，`completedAt` 使用 RFC 3339，
格式不合法返回 `400`。`completed` 为 `true` 时可以携带客户端记录的
`completedAt`；未完成任务的 `completedAt` 始终返回 `null`。

### 4.4 更新任务

```http
PATCH /api/v1/tasks/{id}
Authorization: Session <accessToken>
Content-Type: application/json
```

请求体中的 `baseVersion` 必填：

```json
{
  "completed": true,
  "completedAt": "2026-09-17T10:30:00Z",
  "baseVersion": 1
}
```

`baseVersion` 必须等于服务端当前版本；成功后版本递增并返回更新后的任务。
版本不一致返回 `409 Conflict`。当前 PATCH 是部分更新：省略字段表示保持
原值，显式 `null` 可清空可选字段；对不可为空字段传入 `null` 返回
`400 Bad Request`。

### 4.5 删除任务

```http
DELETE /api/v1/tasks/{id}
Authorization: Session <accessToken>
```

成功返回 `204 No Content`。删除是软删除，实体版本递增，并产生一个
`operation=delete`、`tombstone=true` 的同步事件。

## 5. 项目 API

项目是任务和里程碑的组织容器，不会因为项目截止日期或里程碑截止日期
自动创建日程。

### 5.1 项目响应对象

```json
{
  "id": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f020",
  "name": "毕业设计",
  "goal": "按期完成并答辩",
  "status": "active",
  "startDate": "2026-09-01",
  "due": "2026-12-01",
  "nextActionTaskId": null,
  "createdAt": "2026-09-16T08:00:00Z",
  "updatedAt": "2026-09-16T08:00:00Z",
  "version": 1
}
```

当前响应字段为 `id`、`name`、`goal`、`description`、`color`、`status`、`startDate`、`due`、
`nextActionTaskId`、`createdAt`、`updatedAt` 和 `version`。

`status` 的数据库允许值为 `active`、`completed`、`archived`；创建时
省略则为 `active`。

### 5.2 查询项目

```http
GET /api/v1/projects
Authorization: Session <accessToken>
```

返回 `{items,nextCursor,hasMore}`。默认按创建时间和 ID 排序；支持
`limit=1..100`、不透明 `after` 游标和 `status=active|completed|archived` 筛选。

### 5.3 创建项目

```http
POST /api/v1/projects
Authorization: Session <accessToken>
Content-Type: application/json
```

请求体支持：

```json
{
  "name": "毕业设计",
  "goal": "按期完成并答辩",
  "description": "服务端与手机客户端联调",
  "color": "sage",
  "status": "active",
  "startDate": "2026-09-01",
  "due": "2026-12-01",
  "nextActionTaskId": null
}
```

成功返回 `201 Created` 和项目对象；`name` 为空返回 `400`。

### 5.4 更新和删除项目

```http
PATCH /api/v1/projects/{id}
DELETE /api/v1/projects/{id}
Authorization: Session <accessToken>
```

PATCH 支持项目创建字段，并要求：

```json
{
  "status": "completed",
  "baseVersion": 1
}
```

版本冲突返回 `409 Conflict`。DELETE 返回 `204 No Content`，使用软删除
并写入同步墓碑事件。

### 5.5 项目摘要

```http
GET /api/v1/projects/{id}/summary
Authorization: Session <accessToken>
```

返回项目对象、任务和里程碑的总数/完成数、合计进度百分比，以及按截止时间
排序的下一项未完成任务。进度计算为：
`(completedTasks + completedMilestones) / (tasks + milestones) * 100`；空项目进度为 `0`。

## 6. 日程 API

日程表示课程或其他具有明确开始和结束时间的事项。只有日程进入
`calendar-events`；任务的 `due` / `dueTime`、项目截止日期和里程碑截止
日期不因此进入日程。

### 5.6 项目里程碑

```http
GET /api/v1/projects/{project_id}/milestones?limit=50&after=<opaque-cursor>
POST /api/v1/projects/{project_id}/milestones
GET/PATCH/DELETE /api/v1/projects/{project_id}/milestones/{id}
Authorization: Session <accessToken>
```

里程碑是项目内的截止事项，不是日程。列表返回 `{items,nextCursor,hasMore}`，
按 `position` 和 ID 排序；每个项目最多 100 个未删除里程碑。更新必须携带
`baseVersion`，完成时间由服务端根据 `completed` 维护，删除通过同步墓碑传播。

### 6.1 日程响应对象

```json
{
  "id": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f030",
  "title": "高等数学",
  "description": "第 3 教学楼",
  "location": "301",
  "startAt": "2026-09-17T08:00:00+08:00",
  "endAt": "2026-09-17T09:40:00+08:00",
  "allDay": false,
  "reminderMinutes": 30,
  "createdAt": "2026-09-16T08:00:00Z",
  "updatedAt": "2026-09-16T08:00:00Z",
  "version": 1
}
```

当前日程响应字段为 `id`、`title`、`description`、`location`、`startAt`、
`endAt`、`allDay`、`reminderMinutes`、`createdAt`、`updatedAt` 和
`version`。当前 HTTP 层不返回任务、项目或外部来源关联字段。

### 6.2 查询日程

```http
GET /api/v1/calendar-events
Authorization: Session <accessToken>
```

返回 `{items,nextCursor,hasMore}`，当前按 `startAt` 和 ID 排序。支持
`limit=1..100`、不透明 `after` 游标，以及 RFC3339 的 `from`（含）和 `to`（不含）时间范围。

### 6.3 创建日程

```http
POST /api/v1/calendar-events
Authorization: Session <accessToken>
Content-Type: application/json
```

请求体：

```json
{
  "title": "高等数学",
  "description": "第 3 教学楼",
  "location": "301",
  "startAt": "2026-09-17T08:00:00+08:00",
  "endAt": "2026-09-17T09:40:00+08:00",
  "allDay": false,
  "reminderMinutes": 30
}
```

`title` 不能为空，`startAt` 和 `endAt` 必须是带时区的 RFC 3339 时间戳，且
`endAt` 不能早于 `startAt`，否则返回 `400 Bad Request`。
成功返回 `201 Created`。

### 6.4 更新和删除日程

```http
PATCH /api/v1/calendar-events/{id}
DELETE /api/v1/calendar-events/{id}
Authorization: Session <accessToken>
```

PATCH 支持日程创建字段，并要求 `baseVersion`。更新时间范围时，新的
`endAt` 仍不能早于新的 `startAt`。版本冲突返回 `409 Conflict`；DELETE
返回 `204 No Content` 并写入删除同步事件。

服务端按实际时间点比较 `startAt` 和 `endAt`，因此不同 UTC 偏移的合法表示
也能正确判断先后；响应暂时保留客户端提交的 RFC 3339 表示。

## 7. 手机端连接与聊天消息

### 7.1 聊天消息

```http
GET /api/v1/conversations/{conversation_id}/messages
POST /api/v1/conversations/{conversation_id}/messages
Authorization: Session <accessToken>
```

消息创建请求为 `{"id":"<optional-local-id>","content":"...","attachments":[{"id":"<attachment-id>"}]}`；
附件内容先通过上传接口提交，消息接口只接受附件 ID，服务端按当前用户和会话重新解析规范元数据。
`content` 可以为空，但至少要有一个附件；成功返回 `201 Created`，使用同一消息 ID 重试时返回已有消息。服务端会先保存用户消息，再将
消息异步投递给当前选中的 Hermes 设备，并在收到回复后保存 Agent 消息。

GET 默认保持旧客户端的数组响应。请求带 `limit` 或 `after` 时启用分页并返回
`{"items": [...], "nextCursor": "...", "hasMore": true}`。`limit` 范围为 1–500；
`after` 是不透明游标，服务端按 `created_at,id` 升序做 keyset 分页，两个字段共同保证
同一时间戳下消息不会重复或遗漏。拿到 `hasMore=true` 时，将 `nextCursor` 原样用于下一页；
没有更多数据时 `nextCursor` 为 `null`。

上传使用 `multipart/form-data`，字段名为 `files`（Agent 插件也接受 `file`），总大小不超过
48 MiB。附件消息会在手机端显示图片预览或文件卡片。新上传附件的下载 URL 不含令牌，
读取时使用 Session 或 Agent Bearer；旧的带令牌 URL 仍兼容。

### 7.2 手机端 WebSocket

```text
ws(s)://<server>/api/v1/ws
```

客户端连接后首先发送版本为 `1` 的 `hello` envelope，服务端返回 `hello.ack`，
随后每 20 秒发送 `ping`。客户端应返回 `pong`。该通道当前用于连接保活和后续
变化提示，数据真相仍以 HTTP 同步接口为准。

### 7.3 非语音事件扩展（后续）

以下名称是 v0.3–v0.12 的事件契约，不是 HTTP 路由。Rust 传输层、Hermes v1
适配器和移动端已实现表中非语音事件；command 使用移动端到 Agent 的消息语义桥接，
cron 调度仍由 Hermes 负责：

| 领域 | 事件名称 | 当前可用替代 |
| --- | --- | --- |
| clarify | `clarify.request`、`clarify.resolve`、`clarify.cancel` | `message.send` / `message.reply` 纯文本 |
| approval | `approval.request`、`approval.resolve` | 文本说明并等待用户明确回复 |
| session | `session.start`、`session.update`、`session.complete`、`session.cancel`、`session.error` | HTTP `/api/v1/auth/session`；它不等同于 Agent 执行 session |
| command | `command.request`、`command.reply` | 当前 Rust Gateway 不接受，返回未支持能力 |
| cron | `cron.delivery`、`proactive.delivery` | 当前没有调度器；`recurrence` 只保存 |
| artifact | `artifact`、`artifact.event`、`artifact.completed` | 现有附件上传、下载 URL 和消息附件元数据 |

Rust 结构化事件使用协议目录中的 `event-v1.schema.json`：通用 `event` 信封使用
`event_id` / `event_type` / `sequence` / `payload`，命名扁平事件使用 `event_id` /
`seq` / `session_id` 和同级领域字段。`request_id` / `reply_to` 负责请求关联，未知事件
不得被当作成功；客户端应按 [Agent Gateway fallback 规则](../protocol/agent-gateway/README.md#v012-capabilities-与-fallback)
降级或恢复 HTTP 状态。v0.10 Voice 明确未实现且有意排除。

### 7.4 Hermes 设备切换

```http
GET /api/v1/agent/devices
Authorization: Session <accessToken>
```

响应示例：

```json
{
  "devices": [
    {
      "deviceId": "JXCZ_MBA_Hermes",
      "platform": "macos",
      "client": "hermes",
      "pluginVersion": "0.1.0",
      "lastSeenAt": "2026-09-16T08:00:00Z",
      "online": true,
      "active": true
    }
  ],
  "activeDeviceId": "JXCZ_MBA_Hermes"
}
```

切换设备：

```http
POST /api/v1/agent/devices/JXCZ_WIN_Hermes/select
Authorization: Session <accessToken>
```

设备上线、下线和选择变化会通过手机 WebSocket 发送 `event`，其中
`payload.kind` 为 `agent_devices_changed`；客户端收到后重新查询上述 HTTP 接口。

## 8. 增量同步事件

### 8.1 查询事件

```http
GET /api/v1/sync/events?after=42&limit=100
Authorization: Session <accessToken>
```

查询参数：

| 参数 | 默认值 | 范围 | 说明 |
| --- | ---: | ---: | --- |
| `after` | `0` | 整数 | 只返回 `cursor` 大于该值的事件 |
| `limit` | `100` | 1–500 | 返回数量上限；超出范围时服务端钳制 |

响应：

```json
{
  "events": [
    {
      "cursor": 43,
      "entityType": "task",
      "entityId": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f010",
      "operation": "upsert",
      "entityVersion": 2,
      "tombstone": false,
      "payloadJson": "{\"id\":\"0198f3b5-2d5a-7abc-8f14-7e46e6d7f010\"}",
      "createdAt": "2026-09-16T08:05:00Z"
    },
    {
      "cursor": 44,
      "entityType": "task",
      "entityId": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f010",
      "operation": "delete",
      "entityVersion": 3,
      "tombstone": true,
      "payloadJson": null,
      "createdAt": "2026-09-16T08:06:00Z"
    }
  ],
  "nextCursor": 44
}
```

当前事件字段：

- `entityType`：`task`、`project`、`calendar_event` 或 `project_milestone`。
- `operation`：`upsert` 或 `delete`。
- `entityVersion`：事件对应实体版本。
- `tombstone`：删除事件为 `true`，普通 upsert 为 `false`。
- `payloadJson`：upsert 时为 JSON 文本，delete 时为 `null`。
- `cursor`：按用户递增；客户端只应在成功处理事件后保存 `nextCursor`。

创建、更新和软删除任务、项目、日程及里程碑都会追加事件。实体写入与事件
追加在同一 SQLite 事务中提交；任一步失败都会回滚，避免形成同步缺口。

快照读取和游标读取均按当前用户隔离；快照用于首次同步、本地损坏或客户端游标
失效后的恢复。历史批量导入不会写入这些实时同步事件。

## 9. 完整同步快照

该接口用于游标失效、首次同步或本地数据损坏时的恢复。当前返回任务、项目、
日程和未删除的项目里程碑。

```http
GET /api/v1/sync/snapshot
Authorization: Session <accessToken>
```

建议返回：

```json
{
  "cursor": 44,
  "tasks": [],
  "projects": [],
  "calendarEvents": [],
  "milestones": []
}
```

契约要求：

1. 快照必须在一个一致性边界内读取，并返回生成时用户最新的同步游标。
2. `tasks`、`projects`、`calendarEvents` 和 `milestones` 使用与各自资源 API 相同的
   `camelCase` 对象结构。
3. 快照代表完整当前状态；客户端恢复时应替换本地对应数据集，而不是
   把快照对象当作普通增量事件重复合并。
4. 默认只返回当前实体。若需要清理本地幽灵数据，替换数据集本身即可；
   不应依赖“缺少某个对象”来表示单条删除事件。
5. 快照读取完成后，客户端从返回的 `cursor` 继续请求
   `/api/v1/sync/events?after=<cursor>`。

## 10. `Idempotency-Key`

写入接口接受 `Idempotency-Key`。服务端按用户和 Key 检查已成功处理的重复
写入，并将 Key 与同步事件关联；客户端应在网络超时后复用原 Key。当前实现对
已出现在同步事件中的重复 Key 返回 `409 Conflict`，而不是普遍重放第一次响应；
客户端应读取资源或同步流确认第一次请求是否已经成功。

建议所有业务写入请求支持：

```http
Idempotency-Key: 01J7...client-generated-key
```

适用范围：

- `POST /api/v1/tasks`
- `PATCH /api/v1/tasks/{id}`
- `DELETE /api/v1/tasks/{id}`
- `POST /api/v1/projects`
- `PATCH /api/v1/projects/{id}`
- `DELETE /api/v1/projects/{id}`
- `POST /api/v1/projects/{project_id}/milestones`
- `PATCH /api/v1/projects/{project_id}/milestones/{id}`
- `DELETE /api/v1/projects/{project_id}/milestones/{id}`
- `POST /api/v1/calendar-events`
- `PATCH /api/v1/calendar-events/{id}`
- `DELETE /api/v1/calendar-events/{id}`
- `POST /api/v1/conversations/{conversation_id}/attachments`

当前与目标语义：

1. Key 由客户端生成；当前服务端按“用户 + Key”检查实体同步事件，客户端仍应
   为每个逻辑写入使用唯一 Key，不要跨方法或路径复用。
2. 当前实体 mutation：同一用户的 Key 一旦和同步事件关联，再次使用返回
   `409`，消息为 `Idempotency-Key was already used`；不会重复创建实体或事件。
3. 当前附件上传：同一用户、会话和 Key 会返回第一次保存的上传响应；Key 被
   用于不同会话或不同请求时不能视为同一操作。
4. 首次成功实体写入时，Key 与实体变更、同步事件在同一事务中保存。
5. 业务校验失败不会追加同步事件；网络超时后可复用原 Key，先用 GET/sync
   核对结果，再决定是否生成新 Key。
6. 后续 v1.x 可增加“同请求重放原响应”和请求体指纹校验；客户端不得提前依赖
   尚未由 capabilities 声明的行为。

服务端将 `mutation_id` 作为同步事件字段返回。当前 API 不要求客户端把 Key 放进
JSON body。

## 11. 版本、同步和任务/日程边界

这三个概念不能混用：

| 概念 | 作用 | 当前形态 |
| --- | --- | --- |
| `version` | 单个任务、项目或日程的乐观并发控制 | 更新请求使用 `baseVersion` |
| `cursor` | 当前用户同步事件流的位置 | `GET /api/v1/sync/events` 返回 |
| `baseVersion` | 客户端声明它基于哪个实体版本修改 | 仅 PATCH 请求体字段 |

任务和日程的判断规则：

- 有截止日期/截止时间但没有明确时间段的内容，属于任务。
- 有明确 `startAt` 和 `endAt` 的课程或其他时间安排，属于日程。
- 任务不因 `due`、`dueTime` 或提醒配置自动生成 `calendar-event`。
- 项目和里程碑是任务组织与进度数据，不自动生成日程。

## 12. 错误格式

当前业务错误使用以下 JSON 结构：

```json
{
  "error": "conflict",
  "message": "task version changed"
}
```

当前错误码和 HTTP 状态：

| HTTP | `error` | 使用场景 |
| ---: | --- | --- |
| 400 | `bad_request` | 标题为空、时间范围无效、`dueTime` 缺少 `due` |
| 401 | `unauthorized` | 缺少、失效或过期 Session |
| 404 | `not_found` | 用户范围内找不到实体 |
| 409 | `conflict` | 用户名重复或 `baseVersion` 冲突 |
| 500 | `database_error` | 数据库请求失败；详细错误只写入服务端日志 |

未知路由当前使用特殊结构：

```json
{
  "error": "route_not_found",
  "service": "orialis"
}
```

JSON 解析失败等由 Axum 提取器直接生成的错误，当前不一定符合上述结构。
后续建议统一为同一个错误信封，并为验证错误增加稳定的字段路径信息，
例如 `details.field`。

## 13. 当前实现限制与后续优先级

当前 API 已完成第一轮服务端路线图。以下是明确保留到后续产品阶段的能力边界：

- 任务、项目、里程碑和日程的 PATCH 已区分字段省略与显式 `null`。
- 任务/项目日期、任务截止时间和日程 RFC3339 时间戳已做格式校验。
- 任务 `recurrence` 当前只作为字符串保存，没有循环任务执行器。
- 里程碑通过项目嵌套路由提供 CRUD、乐观并发控制和删除墓碑事件。
- `sync/snapshot` 当前未包含独立的生成时间字段；客户端应以返回的 `cursor`
  作为恢复边界。
- 项目、日程和里程碑列表支持不透明游标分页；日程支持时间范围查询。
- 手机 WebSocket 提供握手、心跳、同步变化提示和聊天消息推送；持久化状态仍以
  HTTP 增量同步和消息查询为准。
- 聊天消息会保存用户消息；Agent 不在线时进入持久化投递队列，连接恢复后自动重试，
  直到匹配的 Agent 回复成功保存。

- 方寸导入使用 `scripts/import-fangcun.py`，先执行 `--dry-run`；历史导入不伪造
  `sync_events`，报告保存在 `migration_batches`。
- 网页、内置 LLM、第三方日历连接和循环任务执行器不属于当前服务端路线图。
