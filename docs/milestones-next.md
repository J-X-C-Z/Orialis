# Project Milestones API 下一阶段设计

> 范围：审查 `fangcun-backup` 与当前 Orialis 模型后，为 `project_milestones` API 固化下一阶段契约。
>
> 本文记录边界和迁移注意事项；第 2–6 节已落实为当前服务端 API，第 8 节保留
> 尚未完成的验收项。

## 1. 审查结论

Fangcun 将里程碑作为项目 JSON 内的 `milestones[]` 数组处理，相关校验位于 `rust-server/src/agent.rs`：

- 每个项目最多 100 项；
- `title` 必须是去除首尾空白后 1–200 个字符；
- `due` 必须是 `YYYY-MM-DD`，或者使用空字符串表示没有截止日期；
- `completed` 必须是布尔值；
- `completedAt` 由服务端根据 `completed` 生成，完成时写入，恢复未完成时清空；
- 旧项目更新时可以整体替换 `milestones` 数组，因此数组内 ID、顺序和删除都隐含在一次项目写入中。

Fangcun 的项目进度投影还把“已完成里程碑”和“已完成项目任务”合并计算：

```text
totalUnits     = milestoneCount + projectTaskCount
completedUnits = completedMilestoneCount + completedTaskCount
progress       = completedUnits / totalUnits * 100
```

这部分可以作为 Orialis 后续项目详情/摘要接口的计算规则，但不应把 `progress` 写入里程碑表，也不应把里程碑转换成日程。里程碑仍然是项目内的截止事项。

当前 Orialis 已通过项目嵌套路由提供里程碑 CRUD。表结构具备 `position`、`version`、
`deleted_at` 和完成状态约束，适合作为独立资源的基础。

## 2. 推荐资源边界

采用项目嵌套资源作为正式入口。`project_id` 从路径取得，不接受客户端在请求体中覆盖：

| 方法 | 路由 | 用途 |
| --- | --- | --- |
| `GET` | `/api/v1/projects/{project_id}/milestones` | 列出项目下未删除的里程碑 |
| `POST` | `/api/v1/projects/{project_id}/milestones` | 创建里程碑 |
| `GET` | `/api/v1/projects/{project_id}/milestones/{id}` | 获取单个里程碑，可选但建议提供 |
| `PATCH` | `/api/v1/projects/{project_id}/milestones/{id}` | 按版本更新里程碑 |
| `DELETE` | `/api/v1/projects/{project_id}/milestones/{id}` | 软删除里程碑并产生墓碑事件 |

第一版不建议提供顶层 `/api/v1/milestones` 写入入口，也不建议继续使用“更新项目时整体提交 `milestones` 数组”的兼容写法。嵌套路由能直接表达父子关系，并使用户归属校验集中在项目上。

建议的排序规则是：

```text
ORDER BY position ASC, id ASC
```

第一版可以通过 PATCH 更新 `position` 实现简单排序；不强制 `position` 唯一，避免交换两个位置时制造不必要的约束冲突。后续如果客户端需要一次拖拽重排，再增加专用批量排序接口和单独的幂等语义。

## 3. 字段契约

### 3.1 返回对象

返回对象采用 camelCase，与当前 `orialis-core::Milestone` 的序列化约定一致：

| 字段 | 类型 | 客户端可写 | 约束与语义 |
| --- | --- | --- | --- |
| `id` | UUID 字符串 | 否（创建时可省略） | 服务端生成 UUIDv7；迁移旧数据时通过映射表转换旧 ID |
| `userId` | UUID 字符串 | 否 | 从 Session 推导；不从请求体读取 |
| `projectId` | UUID 字符串 | 否 | 来自路径；必须属于当前用户且项目未删除 |
| `title` | 字符串 | 创建必填，更新可选 | trim 后 1–200 个 Unicode 字符；空白标题拒绝 |
| `due` | `YYYY-MM-DD` 或 `null` | 是 | 截止日期，不是时间段；Orialis 规范使用 `null` 清空，迁移旧空字符串为 `null` |
| `completed` | 布尔值 | 是 | 默认 `false`；只允许服务端同步维护 `completedAt` |
| `completedAt` | RFC3339 时间戳或 `null` | 否 | `completed=true` 时由服务端写入当前时间；恢复为 false 时清空 |
| `position` | 非负整数 | 是 | 默认 0；用于项目内排序，不代表进度百分比 |
| `createdAt` | RFC3339 时间戳 | 否 | 服务端生成，创建后不可变 |
| `updatedAt` | RFC3339 时间戳 | 否 | 每次有效更新由服务端刷新 |
| `version` | 正整数 | 否 | 创建为 1；每次更新/删除递增，用于乐观并发控制 |
| `deletedAt` | RFC3339 时间戳或 `null` | 否 | 正常列表不返回已删除项；仅在同步墓碑或恢复投影中表达删除 |

`userId` 当前存在于核心模型中，但当前 SQL 表没有该列。实现 API 时应继续以项目的 `user_id` 作为归属事实，二选一：

1. 保持表结构不加 `user_id`，查询里通过 `JOIN projects` 得到用户归属，并让返回 DTO 从父项目注入 `userId`；
2. 增加冗余 `user_id` 列并建立一致性约束。

本阶段推荐方案 1，避免复制项目归属字段导致不一致；但应在 handler 层统一封装“按当前用户读取里程碑”的查询，不能只按 `id` 查询。

### 3.2 创建请求

```json
{
  "title": "完成开题报告",
  "due": "2026-10-15",
  "completed": false,
  "position": 0
}
```

规则：

- `title` 必填；
- `due`、`completed`、`position` 可选，默认分别为 `null`、`false`、当前项目里未删除里程碑数量；
- 忽略或拒绝 `userId`、`projectId`、`completedAt`、`createdAt`、`updatedAt`、`version`、`deletedAt`；推荐对未知字段直接返回 400，尽早暴露客户端契约错误；
- 创建前检查项目下未删除里程碑数量，达到 100 返回 400；这个限制不能只依赖数据库 CHECK，因为它是跨行约束。

### 3.3 更新请求

```json
{
  "title": "完成开题报告初稿",
  "due": null,
  "completed": true,
  "position": 1,
  "baseVersion": 1
}
```

规则：

- `baseVersion` 必填，且必须等于当前 `version`；不匹配返回 409，并返回当前对象或至少返回当前版本；
- PATCH 只修改请求中出现的业务字段；空 PATCH 拒绝；
- `completedAt` 不接受客户端写入；`completed` 从 false 变 true 时服务端写入时间，从 true 变 false 时清空；重复设置同一状态不应伪造新的完成时间；
- `projectId` 不可变。若未来需要移动里程碑，应定义单独的 move 接口，检查源项目和目标项目都属于当前用户，并在一个事务中完成；
- `due: null` 清空截止日期；可在迁移兼容层暂时接受 `""`，但返回统一为 `null`；
- 不增加开始时间、结束时间、提醒时间等字段。里程碑没有确定工作时间段，不进入 `calendar_events`。

## 4. 同步与事务要求

每个创建、更新、删除操作必须与 `sync_events` 写入处于同一个 SQLite 事务中，避免实体已经改变但客户端收不到事件。

事件建议使用：

```text
entity_type = project_milestone
entity_id   = milestone.id
operation   = upsert | delete
version     = 写入后的 milestone.version
tombstone   = false | true
payload     = upsert 时的完整返回对象；delete 时为空
```

具体要求：

- 创建：`version=1`，追加 `upsert` 事件；
- 更新：校验 `baseVersion`，更新实体并递增版本，再追加 `upsert`；
- 删除：设置 `deleted_at`、刷新 `updated_at`、递增版本，再追加 `delete` 且 `tombstone=true`；
- 重试：沿用已确认的 `mutation_id` 幂等机制，避免网络重试创建重复里程碑；
- 普通列表排除 `deleted_at IS NOT NULL`，增量同步必须保留删除墓碑直到同步保留期结束；
- 里程碑的实体 `version`、用户同步 `cursor`、旧 Fangcun 文档 `revision` 不能混用。

## 5. 项目删除的级联策略

当前 SQL 定义 `project_milestones.project_id REFERENCES projects(id) ON DELETE CASCADE`，但 Orialis 的项目删除是软删除。软删除不会触发 SQLite 的物理级联，因此如果只把项目写入 `deleted_at`，子里程碑仍可能是“未删除”状态。

实现项目删除或恢复前必须明确以下行为：

- 删除项目时，在同一事务中软删除其所有未删除里程碑，并为每个里程碑追加墓碑事件；
- 项目删除后，嵌套里程碑 API 对该项目返回 404，而不是泄露仍存在的子记录；
- 不提供 API 物理删除项目或里程碑；数据库级 `ON DELETE CASCADE` 只作为异常清理保护，不能当作同步机制；
- 如果未来支持项目恢复，应同时恢复哪些里程碑、如何区分用户单独删除的里程碑，需要另行定义。第一版建议不开放项目恢复。

这里会产生一个实现选择：项目删除是否要为大量子里程碑逐条生成事件。M1 推荐逐条生成，保证每个客户端都能删除本地缓存；若将来项目规模导致事件数量过大，再增加批量墓碑协议，而不是静默省略子记录事件。

## 6. 迁移 Fangcun 数据的注意事项

旧数据形态和 Orialis 的差异如下：

| Fangcun | Orialis | 注意事项 |
| --- | --- | --- |
| 项目内 `milestones[]` | 独立 `project_milestones` 行 | 先导入项目，再拆分里程碑 |
| 任意旧字符串 ID | UUIDv7 | 建立旧 ID → 新 UUID 映射；同一用户范围内保持引用稳定 |
| 空字符串 `due` | `NULL` | 空字符串、缺失字段统一为空值 |
| 缺失 `completed` | `false` | 非布尔值不默默转 truthy；记录迁移警告并按默认值处理 |
| 缺失 `completedAt` | 服务端时间或 `NULL` | 已完成但缺少时间时使用迁移时间，并在报告中标记推断 |
| 数组顺序 | `position` | 按原数组索引写入，从 0 开始；重复/非法顺序归一化 |
| 项目整体更新 | 独立 CRUD + 增量事件 | 不把旧数组替换协议作为正式 Orialis 同步协议 |

迁移顺序：


1. 建立用户和项目映射；
2. 校验每个旧项目的里程碑数组，超过 100 项时不截断，拆分前记录迁移错误并进入人工处理清单；
3. 为每个合法里程碑生成 UUIDv7，保留旧 ID 映射；
4. 规范化标题、日期、完成状态和顺序；
5. 检查项目归属，禁止把来自其他用户或无法解析父项目的里程碑挂入当前用户；
6. 以迁移批次写入，不把历史导入伪装成客户端逐条操作；如果导入需要可同步，应明确生成初始快照/游标，而不是伪造实时修改事件；
7. 输出成功、跳过、冲突、父项目缺失、ID 转换和字段修正数量。

## 7. 实现前必须修正的模型差异

正式写 API 前，下一次代码改动需要先处理这些已确认差异：

1. `orialis-core::Milestone` 包含 `user_id`，而 `project_milestones` 表没有 `user_id`；确定采用 JOIN 注入还是补列，本文件推荐 JOIN。
2. `orialis-core::Project` 包含 `description`，SQL 表也有该列，但当前 server 的 `Project` DTO 和项目查询没有读取/写入它。
3. SQL 表有 `projects.color`，当前 core/server 项目模型没有暴露它；决定保留为展示元数据，还是延后加入模型。不要在里程碑 API 中隐式带出未统一的项目字段。
4. 里程碑已使用嵌套路由和独立 DTO；仍需补充更完整的同步事务测试。
5. 项目删除已处理子里程碑软删除和对应墓碑事件；仍需将整个操作收束到同一事务。
6. 进度、已完成数量和下一行动是读取投影，不写入 `project_milestones`；它们应在项目详情/摘要 API 中单独设计。

## 8. 下一阶段验收标准

- 同一用户可以创建、读取、更新、软删除里程碑；不同用户不能通过项目 ID 或里程碑 ID访问对方数据；
- 标题、日期、完成状态、位置和 100 项上限校验稳定返回 400；
- `completedAt` 只能由服务端维护，状态恢复会清空；
- 过期 `baseVersion` 返回 409，不覆盖较新的数据；
- 每次写入和同步事件原子提交，删除能通过 tombstone 同步；
- 项目列表/里程碑列表不把里程碑或其截止日期写入日历；
- 项目软删除后子里程碑不会继续出现在正常列表，且客户端能收到对应删除事件；
- 迁移测试覆盖：空数组、缺少字段、旧空字符串日期、重复 ID、超过 100 项、父项目缺失和已完成但缺少 `completedAt`。
