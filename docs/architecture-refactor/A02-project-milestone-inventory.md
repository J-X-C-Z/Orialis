# A02.2 Project/Milestone Mobile domain inventory

> 范围：对实际仓库当前 server 与 mobile 的只读盘点。本文只记录事实和下一步最小实现边界；本轮不修改 mobile/server/protocol，也不提交。

## 结论

server 端的 Project/Milestone 已经是两个可独立同步的实体：`projects` 与
`project_milestones`。Project 是任务和里程碑的组织容器；Milestone 是项目内的
“截止事项”，不是日程。server 已提供嵌套路由、乐观并发、软删除、同步事件和完整
snapshot。

mobile 当前仍只有 `Tasks`、`CalendarEvents`、`Messages`、`Conversations`、
`SyncMetadata`、`OutboxMutations` 六类 Drift 表；没有 Project/Milestone 本地模型，
也没有对应 HTTP 写入、outbox 推送或增量事件应用。因此当前 mobile 不能可靠地读取、
创建、修改、删除或恢复 Project/Milestone。

## 1. server 的真实存储字段

来源：`orialis-server/migrations/0001_core_schema.sql:37-60,99-116`。

### Project：`projects`

| 字段 | 存储语义 |
|---|---|
| `id` | 主键，文本 opaque ID；服务端通常生成 UUID |
| `user_id` | 所属用户；所有查询按用户隔离 |
| `name` | 必填；创建/更新校验为 1–120 个字符 |
| `goal` | 可空目标文本 |
| `description` | 可空描述文本 |
| `status` | 必填，`active` / `completed` / `archived`；默认 `active` |
| `start_date` | 可空 `YYYY-MM-DD` |
| `due` | 可空 `YYYY-MM-DD` |
| `color` | 可空颜色值/字符串 |
| `next_action_task_id` | 可空；若非空，必须指向同一项目下当前用户的未删除 Task |
| `deleted_at` | 可空软删除时间；正常资源查询排除非空记录 |
| `created_at`, `updated_at` | UTC ISO-8601 时间文本 |
| `version` | 正整数，乐观并发版本，初始为 1 |

`user_id` 与 `deleted_at` 是数据库归属/生命周期字段，但当前 `Project` HTTP/同步
DTO 不向客户端暴露它们。实际 DTO 及 camelCase 输出字段见
`orialis-server/src/main.rs:327-342`：`id`、`name`、`goal`、`description`、
`color`、`status`、`startDate`、`due`、`nextActionTaskId`、`createdAt`、
`updatedAt`、`version`。

Project 的写入字段和 PATCH 的显式-null/省略语义见
`orialis-server/src/main.rs:344-377`；PATCH 必须携带 `baseVersion`。

### Milestone：`project_milestones`

| 字段 | 存储语义 |
|---|---|
| `id` | 主键，文本 opaque ID |
| `project_id` | 必填父 Project；数据库外键为 `ON DELETE CASCADE`，但业务删除是软删除 |
| `title` | 必填；服务端校验为 1–200 个字符 |
| `due` | 可空 `YYYY-MM-DD`，仅日期，不是时间段 |
| `completed` | 0/1；默认 false |
| `completed_at` | 可空；从未完成→完成时由 server 生成，取消完成时清空 |
| `position` | 非负整数；项目内排序，创建时默认当前未删除数量 |
| `deleted_at` | 可空软删除时间 |
| `created_at`, `updated_at` | UTC ISO-8601 时间文本 |
| `version` | 正整数，乐观并发版本，初始为 1 |

Milestone DTO 还通过父项目 JOIN 注入 `userId`，因此实际同步/HTTP 对象字段为
`id`、`userId`、`projectId`、`title`、`due`、`completed`、`completedAt`、
`position`、`createdAt`、`updatedAt`、`version`、`deletedAt`；见
`orialis-server/src/main.rs:607-622` 和读取 JOIN
`orialis-server/src/main.rs:2726-2749`。数据库本身没有 `project_milestones.user_id`，
用户归属来自 `projects.user_id`。

约束与资源边界：每个 Project 最多 100 个未删除 Milestone；列表按
`position,id` 排序并使用版本为 1 的不透明游标；Project 删除会在同一事务中软删除
子 Milestone 并逐条写墓碑事件。证据见
`orialis-server/src/main.rs:2751-2801,2830-2887,2960-2997`。

## 2. 实际 HTTP 资源形状

路由注册在 `orialis-server/src/main.rs:811-825`：

- `GET/POST /api/v1/projects`
- `GET/PATCH/DELETE /api/v1/projects/{id}`
- `GET /api/v1/projects/{id}/summary`
- `GET/POST /api/v1/projects/{project_id}/milestones`
- `GET/PATCH/DELETE /api/v1/projects/{project_id}/milestones/{id}`

Project summary 是读取投影，不是新的持久化实体：返回 `project`、任务/里程碑总数
与完成数、`totalUnits`、`completedUnits`、`progress`、`nextAction`；字段见
`orialis-server/src/main.rs:647-659`。进度是任务和里程碑完成数合计除以合计数量，
空项目为 0；计算见 `orialis-server/src/main.rs:2400-2454`。

Project/Milestone 的日期不会进入 `calendar_events`。Project/Milestone 都没有
`startAt`/`endAt`；这与 `docs/api-v1.md:447-464` 和现有验收脚本
`scripts/check-milestones.sh:184-188` 一致。

## 3. snapshot 与 sync event 的真实形状

### 增量事件

数据库事件表的真实列是 `cursor`、`entity_type`、`entity_id`、`operation`、
`entity_version`、`tombstone`、`payload_json`、`mutation_id`、时间字段等；见
`orialis-server/migrations/0001_core_schema.sql:144-174`。

HTTP `SyncEvent` 实际序列化字段为：

```json
{
  "cursor": 12,
  "entityType": "project_milestone",
  "entityId": "milestone-id",
  "operation": "upsert",
  "entityVersion": 2,
  "tombstone": false,
  "mutationId": "client-mutation-id",
  "payloadJson": "{\"id\":\"milestone-id\",...}",
  "createdAt": "2026-09-17T00:00:00.000Z"
}
```

DTO 定义见 `orialis-server/src/main.rs:570-595`；查询返回事件并把最后一条事件的
cursor作为 `nextCursor`，见 `orialis-server/src/main.rs:3221-3237`。当前有效
`entityType` 包括 `task`、`project`、`project_milestone`、`calendar_event`，由
数据库约束固定，见 `orialis-server/migrations/0001_core_schema.sql:148-164`。

写入语义：upsert 携带完整实体 JSON 字符串，`tombstone=false`；delete 的
`payloadJson=null`、`tombstone=true`，`deleted_at` 写入事件；事件 cursor 按用户递增。
`append_event` 的实际绑定见 `orialis-server/src/main.rs:1112-1147`。实体变更和事件
追加在同一事务中完成，例如 Milestone upsert 在
`orialis-server/src/main.rs:2873-2886,2943-2956`，删除墓碑在
`orialis-server/src/main.rs:2984-2997`。

### 完整 snapshot

真实返回 DTO 为：

```json
{
  "cursor": 12,
  "tasks": [],
  "projects": [],
  "calendarEvents": [],
  "milestones": []
}
```

`SyncSnapshot` 的 Rust 字段为 `cursor`、`tasks`、`projects`、`calendar_events`、
`milestones`，由 `rename_all = "camelCase"` 输出为 `calendarEvents`；见
`orialis-server/src/main.rs:590-605`。快照只读取当前用户、未删除 Project 及其未删除
Milestone，且 cursor 取同一事务读取时用户事件流的最大值，见
`orialis-server/src/main.rs:3235-3285`。

## 4. mobile 当前缺口

1. **本地结构缺失。** `mobile/lib/core/database/app_database.dart:106-120` 注册的
   表没有 `Projects` 或 `ProjectMilestones`；因此没有本地 `projectId` 父子索引、
   `position` 排序、`deletedAt` 墓碑和独立 `remoteVersion`。
2. **数据库版本/迁移缺失。** 当前 schemaVersion 为 6，迁移只覆盖 task、日程、消息、
   conversation 和 outbox，见 `mobile/lib/core/database/app_database.dart:120-189`。
3. **HTTP client 缺失。** `mobile/lib/core/network/orialis_api_client.dart:233-313`
   只有 Task、CalendarEvent 和 `/sync/events` 方法，没有 Project/Milestone CRUD，
   也没有 `/sync/snapshot` 方法。
4. **push 缺失。** `SyncEngine.syncOnce()` 只调用
   `_pushTasks`、`_pushCalendarEvents` 等，未调用 project/milestone push；见
   `mobile/lib/core/sync/sync_engine.dart:40-55`。
5. **pull 缺失。** `_pull` 仅对 `task` 和 `calendar_event` 的 upsert/delete 分支做
   本地应用，见 `mobile/lib/core/sync/sync_engine.dart:223-360`。因此 server 发出的
   `project`、`project_milestone` 事件会被跳过，但 cursor 仍会前进，形成 mobile 本地
   永久缺数据的同步缺口。
6. **验收覆盖缺失。** 现有 `scripts/check-milestones.sh` 是 server HTTP 验收，覆盖
   snapshot、CRUD、版本冲突、非日程语义和墓碑事件，但没有 mobile Drift、outbox 或
   pull/replay 验收；见 `scripts/check-milestones.sh:133-209`。

## 5. 下一步最小设计（只作为后续实现边界）

### 最小本地表结构

新增两张 Drift 表，并将它们注册到 `AppDatabase`：

```text
projects:
  id PK, name, goal?, description?, color?, status,
  startDate?, due?, nextActionTaskId?, version,
  remoteVersion, localRevision, createdAt, updatedAt, deletedAt?, syncStatus

projectMilestones:
  id PK, projectId, title, due?, completed, completedAt?, position,
  version, remoteVersion, localRevision, createdAt, updatedAt,
  deletedAt?, syncStatus
  index(projectId, deletedAt, position, id)
```

`userId` 不必在单账户 mobile 本地重复存储；server 已以父 Project JOIN 得到归属。
`version` 是实体当前版本，`remoteVersion` 是 mobile 已确认的 server 版本，
`localRevision` 是本地编辑代次；不要把这三个值与 sync `cursor` 混用。Project 删除
需要保留本地 Project 的墓碑，并应用 server 随事务发出的每一个子 Milestone delete
事件。

### 最小版本与写入语义

- 创建从 server `version=1` 开始；每次成功 PATCH 将实体版本加 1。
- 更新和删除均以本地 `remoteVersion` 作为 `baseVersion`；409 保留本地修改并进入
  conflict，不静默覆盖。
- 每个逻辑 outbox mutation 固定一个 `mutationId`，`entityType` 使用准确的
  `project` 或 `project_milestone`；不能使用 `schedule` 或旧的数组整体替换。
- Milestone 的 `projectId` 不可变；`completedAt` 由 server 根据 completed 状态维护。
- 首次同步/游标失效时使用 snapshot 替换两张对应本地数据集，再把 snapshot `cursor`
  写入 `SyncMetadata`；正常增量只在完整处理事件后写 `nextCursor`。
- 为避免当前 `_pull` 的缺口，未知/未实现实体事件不能在“未落库”时推进 cursor；实现
  Project/Milestone 分支前应至少 fail sync 或保留待处理事件。

### 最小验收测试

1. **Schema/migration：** 从 schemaVersion 6 升级后两张表存在；Project 与
   Milestone 字段可 round-trip；`projectId + position + id` 排序稳定；旧 task/日程/
   outbox 数据不丢失。
2. **Snapshot：** fixture 含一个 Project、两个 Milestone、一个已归属 Task；mobile
   调用 `/api/v1/sync/snapshot` 后得到完整父子关系、`version=1`、正确 `remoteVersion`
   和 cursor；重复 snapshot 不生成 outbox mutation。
3. **Incremental upsert：** server 创建/更新 Project 和 Milestone 后，mobile 应用
   `project`/`project_milestone` upsert 的 `payloadJson`；重复事件、旧
   `entityVersion` 不回退本地数据。
4. **Delete/tombstone：** 删除 Milestone 后只软删除本地行；删除 Project 后所有子
   Milestone 的墓碑都能应用；重放 tombstone 幂等，正常列表不再返回它们。
5. **Local push/conflict：** mobile 创建、更新、删除 Project/Milestone 使用固定
   `mutationId`、正确 `baseVersion` 和正确 route；模拟 409 时保持本地 pending/conflict；
   重试同一 mutation 不产生重复 server 行。
6. **Domain boundary：** Project due、Milestone due 不出现在 `calendar_events`；
   summary 的读取投影不写入 Project/Milestone 表。
7. **Cursor safety：** 在处理 `project_milestone` 事件时强制中断或可恢复重试，验证
   未落库事件不会被 cursor 永久跳过；全部处理成功后才推进 `nextCursor`。

## 6. 本轮验证范围

- 已以实际 server 源码、迁移、mobile Drift schema、API client、SyncEngine 和
  `scripts/check-milestones.sh` 交叉核对上述字段与行为。
- 本轮只新增本文件；未修改 `mobile/`、`orialis-server/`、`protocol/`，未运行需要
  外部服务凭据的 live acceptance script，也未提交。
