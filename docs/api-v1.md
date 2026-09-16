# Oris API v1

本文档定义 Oris 当前服务端已经提供的 API，以及下一步建议实现的同步能力。

本文档以 `oris-server/src/main.rs`、`oris-core/src/lib.rs` 和
`oris-server/migrations/` 的当前工作树为准。标记为“建议”的内容仍属于后续
设计，其余接口可作为已完成基础实现的契约使用。

## 1. 基本约定

- 正式 API 前缀为 `/api/v1`。
- `GET /api/health` 是兼容入口；正式健康检查是 `GET /api/v1/health`。
- 请求和响应使用 JSON，字段统一使用 `camelCase`。
- 服务端生成实体 ID，当前为 UUID 字符串，客户端应将其视为不透明值。
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

当前 Session 查询也接受名为 `oris_session` 的 Cookie：

```http
Cookie: oris_session=<accessToken>
```

但当前登录、注册不会自动设置 Cookie，客户端应保存响应中的
`accessToken` 并通过 `Authorization` 头发送。当前注销接口只接受
`Authorization` 头。

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
| GET/POST | `/api/v1/projects/{project_id}/milestones` | 是 | 已实现 | 查询或创建项目里程碑 |
| GET/PATCH/DELETE | `/api/v1/projects/{project_id}/milestones/{id}` | 是 | 已实现 | 查询、更新或软删除里程碑 |
| GET/POST | `/api/v1/calendar-events` | 是 | 已实现 | 查询或创建日程 |
| PATCH/DELETE | `/api/v1/calendar-events/{id}` | 是 | 已实现 | 更新或软删除日程 |
| GET | `/api/v1/sync/events` | 是 | 已实现 | 按游标读取增量事件 |
| GET | `/api/v1/sync/snapshot` | 是 | 已实现 | 获取可替换本地数据的完整快照 |

当前没有网页接口、Agent 接口或第三方日历接口。里程碑已通过项目嵌套路由
对外提供 HTTP API。

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
| `important` | boolean | 重要性，创建时默认为 `false` |
| `urgent` | boolean | 紧急性，创建时默认为 `false` |
| `completed` | boolean | 是否完成，创建时默认为 `false` |
| `due` | string/null | 截止日期 |
| `dueTime` | string/null | 截止时间；没有 `due` 时必须为空 |
| `reminderMinutes` | integer/null | 提前提醒分钟数 |
| `projectId` | string/null | 所属项目 ID |
| `recurrence` | string/null | 当前实现将请求中的 JSON 值转为字符串保存 |
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
  "due": "2026-09-20",
  "dueTime": "23:59",
  "reminderMinutes": 30,
  "projectId": "0198f3b5-2d5a-7abc-8f14-7e46e6d7f020",
  "recurrence": { "frequency": "daily" }
}
```

成功返回 `201 Created` 和任务对象。`title` 为空或只有空白字符返回
`400 Bad Request`；只提供 `dueTime` 而没有 `due` 也返回 `400`。`due` 使用
`YYYY-MM-DD`，`dueTime` 使用本地时间 `HH:MM`，格式不合法返回 `400`。

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

当前响应字段为 `id`、`name`、`goal`、`status`、`startDate`、`due`、
`nextActionTaskId`、`createdAt`、`updatedAt` 和 `version`。

`status` 的数据库允许值为 `active`、`completed`、`archived`；创建时
省略则为 `active`。

### 5.2 查询项目

```http
GET /api/v1/projects
Authorization: Session <accessToken>
```

返回当前用户全部未删除项目的数组，当前按创建时间排序。

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

## 6. 日程 API

日程表示课程或其他具有明确开始和结束时间的事项。只有日程进入
`calendar-events`；任务的 `due` / `dueTime`、项目截止日期和里程碑截止
日期不因此进入日程。

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

返回当前用户全部未删除日程的数组，当前按 `startAt` 排序。暂不支持
时间范围、分页或来源筛选。

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

## 7. 增量同步事件

### 7.1 查询事件

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

当前没有游标过期检测、事件清理策略或快照回退接口。

## 8. 完整同步快照

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

## 9. `Idempotency-Key`

写入接口支持 `Idempotency-Key`。服务端按用户和 Key 拒绝已成功处理的重复
写入，并将 Key 与同步事件关联；客户端应在网络超时后复用原 Key。

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

建议语义：

1. Key 由客户端生成，服务端按“用户 + HTTP 方法 + 路径 + Key”隔离。
2. 同一 Key 重试时，若请求体和目标相同，返回第一次请求的同一业务结果，
   不重复创建实体或同步事件。
3. 同一 Key 被用于不同请求体或不同目标时，返回 `409 Conflict`，错误码
   为 `idempotency_key_reused`。
4. 首次成功写入时，将 Key 与实体变更、同步事件放在同一事务中保存。
5. 失败的业务请求不应占用 Key；服务端错误允许客户端使用同一 Key 重试。
6. 客户端应为每个逻辑写入操作生成新 Key，并在网络超时后复用原 Key。

服务端将 `mutation_id` 作为同步事件字段返回。当前 API 不要求客户端把 Key 放进
JSON body。

## 10. 版本、同步和任务/日程边界

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

## 11. 错误格式

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

## 12. 当前实现限制与后续优先级

当前 API 可以支撑第一轮服务端基础，但以下事项不应被误认为已完成：

- 任务、项目、里程碑和日程的 PATCH 已区分字段省略与显式 `null`。
- 任务/项目日期、任务截止时间和日程 RFC3339 时间戳已做格式校验。
- 任务 `recurrence` 当前只作为字符串保存，没有循环任务执行器。
- 里程碑通过项目嵌套路由提供 CRUD、乐观并发控制和删除墓碑事件。
- `sync/snapshot` 当前未包含独立的生成时间字段；客户端应以返回的 `cursor`
  作为恢复边界。
- 项目、日程和里程碑列表当前仍没有分页或时间范围查询。

建议下一步顺序：项目进度摘要，再为其他资源补齐分页/筛选。
