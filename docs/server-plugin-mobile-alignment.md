# Orialis 三端接口颗粒度对齐文档

> 状态：V1 开发基线
>
> 适用范围：`mobile/`、`orialis-server/`、`integrations/hermes/orialis/`

## 1. 已冻结的业务边界

Task 和 Schedule 是两个不同的业务类型，不能合并成一个数据库表、一个 API
资源或一个业务判断分支。

| 入口 | 负责的数据 | 允许的动作 |
| --- | --- | --- |
| 今日 | Task + Schedule 的只读聚合投影 | 查看、跳转详情 |
| 事件 | Task | 创建、编辑、完成、删除、筛选 |
| 日历 | Schedule | 创建、编辑、删除、按日期查看 |
| 聊天 | Conversation + Message | 对话、附件、Agent 执行 |
| 我的 | Session、设备、同步、设置 | 账户和连接管理 |

明确禁止：Task 出现在 Calendar 列表或月视图；Schedule 被当作可完成 Task；
Today 为了显示两类数据而新增第三种持久化业务实体。

## 2. 三端共同的数据约定

### 2.1 公共同步字段

Task 和 Schedule 各自保留自己的完整字段，但都必须包含以下同步基础字段：

```json
{
  "id": "opaque-id",
  "createdAt": "2026-09-17T08:00:00Z",
  "updatedAt": "2026-09-17T08:00:00Z",
  "version": 1,
  "deletedAt": null
}
```

- `id` 是不透明字符串；本地优先创建时客户端可先生成 ID。
- `updatedAt` 使用 UTC RFC 3339；日期值使用 `YYYY-MM-DD`。
- `version` 用于乐观并发控制；更新和软删除都递增。
- 删除通过 tombstone 同步，不立即物理删除。
- 客户端的 `syncStatus` 是本地字段，不上传到服务端。

### 2.2 Task

```json
{
  "id": "task-id",
  "title": "完成实验报告",
  "notes": "上传 PDF",
  "important": true,
  "urgent": false,
  "completed": false,
  "due": "2026-09-20",
  "dueTime": "23:59",
  "reminderMinutes": 30,
  "projectId": null,
  "recurrence": null,
  "createdAt": "2026-09-17T08:00:00Z",
  "updatedAt": "2026-09-17T08:00:00Z",
  "version": 1
}
```

Task 表示可完成的行动项。`due` 是截止，不代表一个时间段；Task 不进入
Calendar 的日程查询。

### 2.3 Schedule

```json
{
  "id": "schedule-id",
  "title": "物理实验课",
  "description": null,
  "location": "实验楼 302",
  "startAt": "2026-09-18T09:00:00Z",
  "endAt": "2026-09-18T11:00:00Z",
  "allDay": false,
  "reminderMinutes": 30,
  "createdAt": "2026-09-17T08:00:00Z",
  "updatedAt": "2026-09-17T08:00:00Z",
  "version": 1,
  "deletedAt": null
}
```

Schedule 表示明确的时间安排，没有 `completed`、`important`、`urgent` 或
`due` 语义。服务端当前数据库表仍叫 `calendar_events`，这是存储兼容细节，
新客户端代码统一使用 `Schedule`。

## 3. HTTP API 对齐

### 3.1 现有接口保持不变

以下接口是 V1 稳定接口，服务器端不得改变字段含义：

```text
GET/POST   /api/v1/tasks
PATCH/DELETE /api/v1/tasks/{id}
GET/POST   /api/v1/calendar-events
PATCH/DELETE /api/v1/calendar-events/{id}
GET/POST   /api/v1/conversations/{conversationId}/messages
POST       /api/v1/conversations/{conversationId}/attachments
GET        /api/v1/attachments/{id}/download
GET        /api/v1/sync/events
GET        /api/v1/sync/snapshot
```

`calendar-events` 是旧的资源名，但当前线上客户端依赖它。服务端可以新增
`/api/v1/schedules` 作为规范名称，但必须保留旧路径至少一个迁移周期；两个
路径必须读写同一张 `calendar_events` 表，并产生同一种同步实体类型。

### 3.2 Schedule 规范别名

新增规范路由：

```text
GET/POST     /api/v1/schedules
PATCH/DELETE /api/v1/schedules/{id}
```

查询参数与旧日历接口一致：`after`、`limit`、`from`、`to`。响应仍为：

```json
{
  "items": [/* Schedule */],
  "nextCursor": "opaque-cursor-or-null",
  "hasMore": false
}
```

同步事件在 V1 使用 `entityType: "calendar_event"`，这是兼容值；客户端映射
为本地 `Schedule`。待所有客户端升级后，才可另行发布 `entityType: "schedule"`
的协议版本，不能在同一版本中混用两种值。

### 3.3 Conversation 接口

Conversation 是 Message 的归属资源，不允许客户端继续只靠硬编码 `default`
会话工作。

```text
GET    /api/v1/conversations
POST   /api/v1/conversations
PATCH  /api/v1/conversations/{id}
DELETE /api/v1/conversations/{id}
GET/POST /api/v1/conversations/{id}/messages
```

请求与响应：

```json
{
  "id": "conversation-id",
  "title": "Orialis 手机端",
  "type": "main",
  "createdAt": "2026-09-17T08:00:00Z",
  "updatedAt": "2026-09-17T08:00:00Z",
  "version": 1,
  "lastMessageAt": "2026-09-17T08:01:00Z",
  "messageCount": 2
}
```

- `type` 只有 `main` 和 `normal`；每个用户只能有一个 `main`。
- `main` 在首次访问或注册时创建，不能删除、不能改成 `normal`。
- 普通会话可创建、重命名和删除；删除是软删除，并同步 tombstone。
- `POST /conversations` 至少接受 `{ "title": "..." }`，服务端生成 ID。
- 消息路径中的 `{id}` 必须校验会话属于当前用户；不存在返回 404。
- 消息创建必须带 `conversationId` 语义，不能把不同会话的消息写入同一流。

### 3.4 Message 与附件

消息的最小结构：

```json
{
  "id": "message-id",
  "conversationId": "conversation-id",
  "role": "user",
  "content": "请整理这张图",
  "createdAt": "2026-09-17T08:01:00Z",
  "version": 1,
  "attachments": [
    {
      "id": "attachment-id",
      "name": "photo.jpg",
      "mimeType": "image/jpeg",
      "size": 123456,
      "downloadUrl": "https://orialis.jxcz.top/api/v1/attachments/attachment-id/download"
    }
  ]
}
```

允许的附件为图片、文本、PDF、JSON、XML、ZIP 和通用二进制文件；单文件上限
20 MB。附件元数据由服务器规范化，Hermes 不得信任客户端提供的本地路径。

## 4. WebSocket / Agent Gateway 对齐

### 4.1 Hermes → Server

```json
{
  "version": 1,
  "type": "message.reply",
  "message_id": "reply-id",
  "reply_to": "user-message-id",
  "conversation_id": "conversation-id",
  "content": "已完成整理"
}
```

`conversation_id` 是必填且必须原样回传。服务端用
`(user_id, conversation_id, reply_to)` 校验归属和幂等性，不能只按
`reply_to` 全局匹配。

### 4.2 Server → Hermes

```json
{
  "version": 1,
  "type": "message.send",
  "message_id": "user-message-id",
  "conversation_id": "conversation-id",
  "content": "请创建一个任务",
  "attachments": []
}
```

插件收到 `message.send` 后必须：

1. 先按 `message_id` 去重，再发送 `message.ack`。
2. 将 `conversation_id` 传入 Hermes 会话上下文。
3. 仅使用明确的 Task 或 Schedule 工具；不创建名为 Event 的第三种业务对象。
4. 回复必须携带同一个 `conversation_id` 和 `reply_to`。
5. 图片/文档附件先通过 `downloadUrl` 下载到受控临时目录，处理完成后清理。

### 4.3 插件工具的语义边界

推荐工具名及最小动作：

```text
list_tasks / create_task / update_task / complete_task
list_schedules / create_schedule / update_schedule / delete_schedule
list_conversations / create_conversation
```

Task 工具只能写 `/tasks`；Schedule 工具只能写 `/schedules`（兼容期也可写
`/calendar-events`）；不能用 `create_task` 携带 `startAt/endAt` 偷换成日程。
插件若要执行跨实体动作，必须拆成两个明确的 API 调用，并在回复中说明结果。

## 5. 同步与实时事件

增量同步统一使用游标：

```json
{
  "cursor": 42,
  "entityType": "task",
  "entityId": "task-id",
  "operation": "upsert",
  "entityVersion": 2,
  "tombstone": false,
  "payloadJson": "{...}",
  "mutationId": "client-mutation-id"
}
```

当前服务端已稳定发出的 `entityType`：`task`、`calendar_event`（映射为 Schedule）、
`project`、`project_milestone`。Conversation 和 Message 在本轮先通过各自 HTTP
接口拉取；下一同步版本再增加 `conversation`、`message` 事件，届时必须升级协议
版本，不能静默改变现有事件集合。

实时通知只表示“有变化”，不是完整数据载荷：

```json
{
  "type": "sync.change_hint",
  "cursor": 42,
  "entity": "task"
}
```

手机端收到提示后调用增量同步；断线重连后也必须先补同步，再恢复实时监听。
Today 不建立自己的同步流，而是从本地 Task 和 Schedule 查询后合并排序。

## 6. 各端必须修改的接口清单

### 服务器端

- 增加 Conversation 持久化表、用户隔离、主会话保护和四个 CRUD 路由。
- 消息 POST 前校验 Conversation 归属；列表接口只返回当前会话消息。
- 增加 `/schedules` 规范别名，同时保留 `/calendar-events`。
- 快照增加 conversations；增量同步增加 conversation/message 事件。
- capabilities 明确声明 `conversations`、`schedules`、`attachments`。
- Agent 回复按 conversation 维度路由、校验和幂等。

### Hermes 插件端

- 所有 gateway frame 固定携带 `conversation_id`。
- 适配新旧 Schedule 路由，但向工具层暴露 `schedule` 术语。
- 增加 Task/Schedule 工具的参数校验，禁止跨类型字段混用。
- 对 `message_id` 做接收去重，对回复保留 `reply_to`。
- 附件只使用服务器返回的元数据和下载 URL，不暴露本地路径给手机端。
- 能力发现结果必须反映服务器真实 capabilities，不把未实现工具伪报为可用。

### 手机端

- 将 Dart 领域名 `CalendarEvent` 改为 `Schedule`；旧数据库表名可保留。
- 保留独立的 Task 表、Schedule 表、Repository 和详情页。
- 新增 Conversation 本地表与 repository；Chat 首页读取会话列表。
- API client 增加 Conversation CRUD 和 `/schedules` 优先、旧路由回退。
- Sync engine 分别处理 Task、Schedule、Conversation、Message 的事件。
- Today 只在查询层聚合，Events/Calendar 不共享错误的业务筛选条件。

## 7. 兼容与发布顺序

1. 先发布服务器 Conversation CRUD、`/schedules` 别名和能力声明；保留旧接口。
2. 再发布 Hermes 的 conversation 透传、Task/Schedule 工具校验。
3. 最后发布手机端本地 `Schedule` 重命名、会话列表和增量同步。
4. 连续一个版本确认无旧客户端后，才评估移除 `calendar-events` 别名；V1 不删除。

## 8. 验收矩阵

| 场景 | 必须成立 |
| --- | --- |
| 新建 Task | 出现在 Events 和 Today，不出现在 Calendar |
| 新建 Schedule | 出现在 Calendar 和 Today，不出现在 Events |
| 删除任一对象 | 通过 tombstone 同步到手机，另一类对象不受影响 |
| 创建普通会话 | Chat 可切换到新会话，消息不会进入 main |
| 删除 main | 服务端拒绝，普通会话可删除 |
| Hermes 回复 | 手机显示在发送消息所属会话，不能串到另一会话 |
| 断线重连 | 先补游标同步，再接收实时提示，不重复消息 |
| 旧客户端 | 继续使用 `/calendar-events` 正常读写 |
