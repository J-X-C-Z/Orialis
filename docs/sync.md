# Orialis V1 同步与事件

同步分为本地 pending queue、push 和 pull：

1. 用户操作先写入 Drift，界面立即响应；
2. `SyncEngine` 发送带 `Idempotency-Key` 的 HTTP mutation；
3. Rust 在实体变更后写入 `sync_events`，实体版本递增；
4. 客户端用 `after=<cursor>` 拉取增量事件；
5. 删除通过 `deleted_at` 和 `tombstone` 传播；
6. 已登录手机通过 `/api/v1/ws` 接收按用户隔离的 `sync.change_hint` 和聊天消息，
   收到提示后仍以 HTTP 增量同步作为最终状态来源；
7. 手机消息在服务端提交后进入 Agent 投递队列；Hermes 暂时离线或响应超时不会丢失，
   服务端按退避策略重试，收到回复并持久化后才移除队列记录。

实体 `version`、本地 `localRevision`、写请求 `baseVersion`、用户同步 `cursor`、
Agent 事件 `seq` 和旧 Fangcun 文档 `revision` 是六个不同概念。Task、Schedule
和 Conversation 都遵循同一语义：`version` 只表示服务器实体版本，
`localRevision` 只表示本地编辑代次，`baseVersion` 只表示本次写入所依据的服务端
版本。V1 不做 CRDT 或自动合并；服务器返回 409 时，本地修改不能被静默覆盖。

## 当前 HTTP 增量事件

请求：

```http
GET /api/v1/sync/events?after=42&limit=100
Authorization: Session <accessToken>
```

响应的 JSON 结构固定为 `{events,nextCursor}`。每个事件的当前字段如下：

| 字段 | 类型 | 语义 |
| --- | --- | --- |
| `cursor` | integer | 当前用户事件流中的单调递增位置，从 1 开始 |
| `entityType` | string | `task`、`project`、`calendar_event` 或 `project_milestone` |
| `entityId` | string | 实体不透明 ID |
| `operation` | string | `upsert` 或 `delete` |
| `entityVersion` | integer | 该实体写入后的版本 |
| `tombstone` | boolean | `delete` 为 `true`，`upsert` 为 `false` |
| `mutationId` | string/null | 请求的 `Idempotency-Key`，没有则为 `null` |
| `payloadJson` | string/null | `upsert` 时为 JSON 文本，`delete` 时为 `null` |
| `createdAt` | RFC 3339 string | 事件创建时间 |

`payloadJson` 是字符串，不是嵌套 JSON object；客户端必须先 `JSON.parse`，再按
对应资源的 `camelCase` 结构应用。删除事件不能依赖 payload；应按
`entityType + entityId` 写入本地墓碑或删除本地活动记录。

```json
{
  "events": [
    {
      "cursor": 43,
      "entityType": "task",
      "entityId": "task_001",
      "operation": "upsert",
      "entityVersion": 2,
      "tombstone": false,
      "mutationId": "mut_001",
      "payloadJson": "{\"id\":\"task_001\",\"title\":\"整理 Orialis 文档\",\"version\":2}",
      "createdAt": "2026-09-17T08:05:00Z"
    },
    {
      "cursor": 44,
      "entityType": "task",
      "entityId": "task_002",
      "operation": "delete",
      "entityVersion": 3,
      "tombstone": true,
      "mutationId": null,
      "payloadJson": null,
      "createdAt": "2026-09-17T08:06:00Z"
    }
  ],
  "nextCursor": 44
}
```

服务端在同一 SQLite 事务中提交实体写入和事件追加。查询按 `cursor` 升序返回；
没有新事件时 `nextCursor` 保持请求的 `after`。客户端只有在成功应用整页事件后
保存 `nextCursor`，不要按到达顺序或本地时间推进游标。

## 幂等与顺序

- 每个逻辑 HTTP mutation 生成一个新的 `Idempotency-Key`；网络超时或断线重试时
  复用原 Key。客户端不要把 Key 放进 JSON body。
- 当前实体 mutation 对已经和同步事件关联的重复 Key 返回 `409`，而不是普遍
  重放第一次响应；收到 409 时通过资源读取或 sync 流核对结果。
- 附件上传对同一用户、会话和 Key 保留第一次上传响应；消息创建还支持用相同
  消息 `id` 重试并返回已存在消息。
- HTTP `cursor` 只表示服务器事件流位置；实体 `version` 只用于 PATCH 的
  `baseVersion`；Conversation rename/delete 也必须携带它。两者都不能代替 Agent
  `message_id` 或未来事件 `event_id`。
- 同一用户的 cursor 严格递增但不承诺实体事件连续相邻。客户端应处理同一实体
  的多个 upsert，并用 `entityVersion` 丢弃较旧事件。
- Agent Gateway 当前用 `message_id` 去重，回复用 `reply_to` 指向原消息。结构化
  event 帧另用 `event_id` 去重、`seq` 排序、`request_id` / `session_id` 关联，规范
  见 [`protocol/agent-gateway/README.md`](../protocol/agent-gateway/README.md)。

## Mobile WebSocket 提示通道

`/api/v1/ws` 与兼容别名 `/api/v1/mobile/ws` 需要 Session 认证。当前 envelope 为：

```json
{
  "version": 1,
  "type": "sync.change_hint",
  "payload": {
    "cursor": 44,
    "entity": "task"
  }
}
```

支持的当前类型是 `hello`、`hello.ack`、`ping`、`pong`、`event`、`message`、
`sync.change_hint` 和 `error`；每 20 秒发送 heartbeat。`event` 与 `message` 是
通知，不是可替代 HTTP 状态的同步记录。若服务端发送 `sync_lagged`，或客户端怀疑
丢失提示，立即从保存的 cursor 重新拉取。

`sync.change_hint` 的 `cursor` 是提示生成时的最新值，不保证客户端下一次请求
恰好只返回一个事件。提示丢失不会造成数据丢失，因为状态恢复依赖 HTTP。

## Snapshot 回退

首次同步、本地数据库损坏或游标无法继续时调用：

```http
GET /api/v1/sync/snapshot
Authorization: Session <accessToken>
```

返回 `{cursor,tasks,projects,calendarEvents,milestones}`，只包含当前未删除数据。
客户端在一个本地事务中替换对应数据集，成功后把返回的 `cursor` 作为新的边界，
再请求 `/api/v1/sync/events?after=<cursor>`。不要把 snapshot 行当成普通 upsert
事件重复排队，也不要在 snapshot 完成前推进旧游标。

## 离线 Agent 与客户端 fallback

手机消息先持久化，再异步投递给当前选中的在线 Hermes 设备。Agent 离线、连接被
替换、回复超时或回复校验失败时，队列记录保留，服务端按退避重试；客户端不应
重复创建用户消息，也不应因为没有实时回复而删除它。

非语音扩展的 fallback 顺序：

1. 先读取 `/api/v1/capabilities`；查询失败时只启用当前 v1 基线。
2. 不支持 `clarify` / `approval` / `command` / `cron` / `artifact` 事件时，
   保留原 ID，改发纯文本摘要或显示待升级状态，不伪造完成。
3. WebSocket 断线时继续 HTTP sync；WebSocket 永远不是唯一数据源。
4. 游标不可恢复时使用 snapshot；409 冲突时保留本地 pending 修改，等待显式冲突处理。
5. v0.10 Voice 是未实现且有意排除的能力；音频、语音和视频不进入 sync、Agent
   WebSocket 或附件 fallback。

## 客户端兼容边界

| 客户端 | 必须支持 | 可以安全忽略 |
| --- | --- | --- |
| Orialis Android v1 | `camelCase` HTTP 资源、`payloadJson` 字符串、cursor、snapshot、mobile heartbeat | 未知 mobile payload 字段 |
| Hermes Orialis v1 | 基线 Agent 帧、`message_id`/`reply_to`、文本和非语音附件、结构化事件 | 未声明的扩展、未知 HTTP capabilities 字段 |
| Orialis macOS / Windows v1.x | 相同 Agent v1 基线；平台值分别为 `macos` / `windows` | 未声明的后续事件类型 |
| HTTP-only 旧客户端 | CRUD、Session、sync/snapshot | WebSocket 和所有 Agent 扩展 |

更完整的 v0.3–v1.x 事件字段、配置、Windows/macOS 和兼容矩阵见
[`protocol/agent-gateway/README.md`](../protocol/agent-gateway/README.md)。
