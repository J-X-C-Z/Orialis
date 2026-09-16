# Fangcun → Orialis 迁移审计

> 审计对象：`fangcun-backup` 分支
>
> 审计范围：任务、项目、课程/日程、同步、认证相关 Rust 代码与文档
>
> 目标：为 Orialis 服务端第一阶段提供可追溯的迁移边界；本文档不是旧代码的复制清单。

## 1. 已确认的 Orialis 边界

Orialis 第一阶段只构建服务端，先完成可独立演进的领域模型、SQLite 数据层、认证、正式 API 和同步基础设施。网页、Agent Runtime、Hermes、LLM、WebSocket、文件上传、穿戴设备、Android UI、Google/Outlook 重新连接均不在本阶段。

API 以 `/api/v1/*` 为正式入口，暂保留 `/api/health` 兼容别名。

业务数据分为两类：

1. **任务**：作业、长期项目行动、每日任务。任务可以有截止日期和截止时间，但没有确定的工作时间段，不自动写入 `calendar_events`。
2. **日程**：课程等具有明确开始时间和结束时间的事项，写入 `calendar_events`。

同步采用已确认方案：

- 每个用户拥有单调递增的同步游标；
- 业务写入同时产生 `sync_events`；
- 删除使用软删除/墓碑，保证其他客户端能收到删除；
- 写入使用实体 `version` 和 `base_version` 做乐观并发控制，冲突返回 `409`；
- 使用 `mutation_id` 做客户端重试幂等；
- 保留完整快照作为首次同步、恢复和游标失效后的重建手段。

## 2. 审计结论总表

| 来源 | 结论 | 迁移说明 |
| --- | --- | --- |
| `rust-core/src/lib.rs` 的任务/课程字段读取 | **ADAPT** | 字段语义和课程排课算法有价值，但必须改为 Orialis 类型模型；任务不再投影为日历事件 |
| `rust-core/src/lib.rs` 的四象限推导 | **REUSE** | `important`/`urgent` 的四种组合保持不变；Orialis 不把 `quadrant` 作为事实字段 |
| `rust-core/src/lib.rs` 的课程周次、节次、例外处理 | **ADAPT** | 保留取消、调课、节假日和节次覆盖行为，输出改为 `calendar_events` |
| `rust-server/src/agent.rs` 的任务校验 | **ADAPT** | 校验规则、PATCH 语义和关联对象校验可提取；改用 SQLx、UUID、实体版本和 Orialis 命名 |
| `rust-server/src/agent.rs` 的项目/里程碑校验 | **ADAPT** | 名称、日期、里程碑数量和状态语义可保留；里程碑拆为独立表 |
| `rust-server/src/agent.rs` 的循环任务生成 | **ADAPT / 暂缓实现** | 仅提取规则作为迁移参考；在时区、幂等和并发语义明确前不直接上线旧实现 |
| `rust-server/src/main.rs` 的认证实现 | **ADAPT** | scrypt、Session 令牌和 30 天有效期可保留行为；数据库、字段、Cookie 名称和错误处理改为 Orialis 版本 |
| `rust-server/src/main.rs` 的 `user_states`/`user_snapshots` | **REWRITE** | 只能作为一次性导入来源；Orialis 不以整份 JSON 文档作为主存储 |
| `rust-server/src/main.rs` 的数据库初始化 | **REWRITE** | 旧代码在运行时拼接 DDL；Orialis 使用 SQLx `SqlitePool` 和版本化 migrations |
| `rust-server/src/sync.rs` 的 Google/Outlook 同步 | **暂缓 / REWRITE** | 第三方 OAuth 和双向日历同步不属于当前范围；旧的整文档回写也不符合 Orialis 同步模型 |
| `docs/API-V1.md`、`docs/FLUTTER-SERVER-CHANNEL.md` 的完整文档同步协议 | **REWRITE** | 旧协议是完整文档替换；保留兼容思路，正式协议改为实体 API + 增量事件 |
| `docs/AGENT-API.md` | **暂缓** | Agent API 不进入当前服务端迭代；其中的任务/项目字段校验可作为后续客户端契约参考 |
| `docs/LINK-DATA-CONTRACT.md` | **暂缓** | 穿戴设备只读快照不进入当前实现；其中的稳定 ID、版本和只读边界可作为未来适配参考 |

## 3. 来源审计明细

### 3.1 `rust-core/src/lib.rs`

旧核心以 `serde_json::Value` 读取网页端的大文档，顶层约定包含 `tasks`、`projects`、`courses`，另有 `semester`、`timeSlots`、`courseExceptions`、`calendarRules`。它没有形成可直接用于 Orialis 的强类型领域模型，但其中的行为规则值得保留。

可提取的行为：

- 未完成任务才参与旧的日历事件生成；
- 任务优先使用 `startDate`/`startTime`，没有时才使用 `due`/`dueTime`；
- 任务有日期但没有时间时按全天事件处理；有时间但没有结束时间时，起始任务默认延长 60 分钟，只有截止时间的任务默认延长 15 分钟；
- 课程以学期开始日期、周次、星期和节次计算实际日期；
- `cancel` 例外取消课程，`targetDate` 支持调课，例外还可以覆盖起止节次；节假日规则可以跳过课程；
- 课程事件的稳定旧键为 `course:<course_id>:<原始日期>`。

Orialis 的关键行为差异是：任务无论有无 `due`/`due_time`，都不因截止信息自动生成 `calendar_events`。只有课程/日程进入日程表。旧任务中的 `startDate` 等字段如需保留，最多作为兼容导入数据，不能恢复旧的“任务即日历事件”行为。

### 3.2 `rust-server/src/agent.rs`

该文件是旧服务中最完整的任务和项目写入校验来源，但它操作的是 `user_states.document`：读取完整 JSON、修改数组、递增整份文档 `revision`，再整体写回。

任务校验与更新行为：

- 创建任务要求 `title` 为 1–120 个字符；`notes` 最多 2000 个字符；
- `due` 为 `YYYY-MM-DD`，`dueTime` 为 `HH:mm`，有 `dueTime` 必须有 `due`；清空 `due` 时自动清空 `dueTime`；
- `important`、`urgent`、`completed` 必须是布尔值；
- `courseId`、`projectId` 必须属于当前用户，或用空字符串解除关联；
- PATCH 只修改请求中出现的字段，空对象被拒绝；
- 创建时默认未完成，`quadrant` 根据重要/紧急两个布尔值推导；
- 完成任务时写入 `completedAt`，恢复任务时清空它；
- 旧 Agent 创建任务不接受循环字段，但已有循环任务完成时可能生成下一次任务。

项目和里程碑行为：

- 项目 `name` 为 1–120 个字符；`goal`、`color`、`status` 最多 2000 个字符；日期为 `YYYY-MM-DD` 或空字符串；
- 项目默认 `color=sage`、`status=active`，带 `milestones` 数组；
- 里程碑最多 100 项，`title` 为 1–200 个字符，包含 `id`、`title`、`due`、`completed` 和服务端生成的 `completedAt`；
- 旧项目还包含 `nextActionTaskId`，用于指向下一项行动任务；
- 旧项目里程碑是 JSON 内嵌数组，Orialis 将其拆为 `project_milestones`，增加 `position`、`version` 和软删除能力。

循环任务函数支持 `daily`、`weekly`、`weekdays`、`monthly`，使用服务端当前日期作为缺失截止日期的基准，并用 `nextOccurrenceId` 防止重复生成。这些规则可以作为未来 recurrence 模块的测试样例，但旧函数缺少每用户时区、事务级幂等和跨客户端并发设计，不能原样复用。

### 3.3 `rust-server/src/main.rs`

认证相关的可取行为：

- 用户名长度 3–32，只允许字母数字、下划线和连字符；
- 密码长度 8–128；
- 密码使用 scrypt，参数为 `N=16384`、`r=8`、`p=5`，每个密码使用随机 16 字节 salt，输出 64 字节；
- Session 令牌为 32 字节随机值的 base64url 表示，数据库只存 SHA-256 hash；
- Session 支持 `Authorization: Session <token>`，网页端另使用 HttpOnly Cookie；
- 默认 Session 有效期 30 天，用户停用、改密或注销时应使旧 Session 失效；
- 旧服务区分用户 Session 和 Agent Bearer 令牌，不能混用。

存储实现不直接复用：旧代码使用 `Arc<Mutex<rusqlite::Connection>>`，把多张表的 `CREATE TABLE IF NOT EXISTS` 放在应用启动代码中。Orialis 改为 SQLx `SqlitePool`、`ORIALIS_DATABASE_URL` 和 `orialis-server/migrations/`，并在迁移中开启 WAL、外键和必要索引。

### 3.4 `rust-server/src/sync.rs`

该文件实现的是第三方 Google/Outlook OAuth 与双向日历同步：

- 保存第三方 access token、refresh token、日历 ID 和远端事件链接；
- 通过 `local_key`、远端事件 ID、远端版本标签和本地内容 hash 判断变更；
- 远端事件会被转换成旧文档中的任务，导入任务数组；
- 同步完成后整体修改 `user_states.document`，并把 revision 加一；
- 函数结果明确标记 `incremental:false`。

这套实现不能成为 Orialis 内部同步层。它把外部日历事件反向写成任务，正好违反“任务”和“日程”分离的目标；同时 OAuth 密钥、远端冲突和删除策略也需要单独的 provider adapter 设计。因此本阶段仅保留为未来外部集成的风险参考。

### 3.5 文档审计

- `docs/API-V1.md` 宣称 `/api/v1` 是版本化入口，但同时列出完整数据、日历订阅、管理员、Agent 和第三方集成等已迁移能力；这超出本阶段边界。
- `docs/FLUTTER-SERVER-CHANNEL.md` 的启动同步仍是 `GET /api/v1/data` + `PUT /api/v1/data` 的完整文档替换，并以 `baseRevision` 冲突重试；这只能作为兼容过渡，不是 Orialis 的正式增量协议。
- `docs/AGENT-API.md` 记录了任务和项目字段约束、`Authorization: Bearer`、令牌 hash、限流和审计；Agent 相关内容暂不实现。
- `docs/LINK-DATA-CONTRACT.md` 定义了稳定 ID、revision/cursor 和只读快照，但目标是手机/手环互联，当前不纳入 Orialis 服务端实现。
- 上述文档以及 `rust-server/src/main.rs`、`rust-server/README.md` 含有未解决的 `<<<<<<<`、`=======`、`>>>>>>>` 冲突标记，不能把整文件视为可信的最终规范。迁移时以可验证的字段和函数行为为准，并以本文档和后续 Orialis API 契约为准。

## 4. 字段映射

### 4.1 通用规则

旧 JSON 使用 camelCase、毫秒时间戳和用户文档内隐式归属；Orialis 使用数据库列和 Rust 类型。所有实体都增加 `user_id` 外键、`created_at`、`updated_at`、`version`；需要删除同步的实体增加 `deleted_at`。ID 迁移到 UUID，优先 UUIDv7。旧 ID 必须建立映射，不能假设旧的随机字符串等于新的 UUID。

### 4.2 任务映射

| Fangcun 字段 | Orialis 字段 | 处理 |
| --- | --- | --- |
| `id` | `tasks.id` | 转换为 UUID；保留旧 ID 映射，避免关联断裂 |
| 文档归属 | `tasks.user_id` | 从所属 `user_states.user_id` 迁入 |
| `title` | `title` | 保留，创建和 PATCH 的长度/非空校验保留 |
| `notes` | `notes` | 保留；空字符串按清空处理 |
| `important` | `important` | 保留布尔值，默认 `false` |
| `urgent` | `urgent` | 保留布尔值，默认 `false` |
| `quadrant` | 派生值 | 不作为权威存储；按 `important` + `urgent` 推导 q1/q2/q3/q4 |
| `completed` | `completed` | 保留 |
| `completedAt` | `completed_at` | 毫秒时间戳转统一时间类型；恢复时为空 |
| `due` | `due` | `YYYY-MM-DD` 转日期；这是截止日期，不是日程开始时间 |
| `dueTime` | `due_time` | `HH:mm` 转时间；没有 `due` 时必须为空 |
| `startDate`/`startTime` | 可选 `start_at` | 仅为兼容导入保留；不因此生成日程 |
| `endDate`/`endTime` | 可选 `end_at` | 仅为兼容导入保留；不因此生成日程 |
| `projectId` | `project_id` | 转换后校验属于同一用户 |
| `courseId` | 暂不作为任务主关联 | 旧任务课程关联可保留为迁移备注；课程本身进入日程模型 |
| `repeat` | recurrence 字段组 | 保留可迁移信息；旧自动生成逻辑暂不直接上线 |
| `nextOccurrenceId` | recurrence 关联/幂等信息 | 不直接照搬；由未来 recurrence 设计决定 |
| `recurrenceSourceId` | recurrence 来源 ID | 可保留为来源映射 |
| `reminderMinutes` | `reminder_minutes` | 保留为任务提醒配置，不产生日程记录 |
| `type` | `task_type` 或来源标记 | 只保留能表达 Orialis 业务的值，不把旧 `event` 类型混入普通任务 |
| `source` | `source` | 作为导入来源审计信息，不改变任务/日程分类 |
| `today` | 不迁移为事实字段 | “今天”应按用户时区和查询日期计算 |
| `createdAt`/`updatedAt` | `created_at`/`updated_at` | 毫秒时间戳转统一时间；同时初始化 `version` |

旧的 `local_events()` 会把有 `due` 的任务显示为 `DDL · 标题`，并将任务转换成全天或定时事件。Orialis 不复用这个投影；任务只返回任务 API，日程只返回 `calendar_events`。

### 4.3 项目与里程碑映射

| Fangcun 字段 | Orialis 字段 | 处理 |
| --- | --- | --- |
| 项目 `id` | `projects.id` | 转 UUID并建立旧 ID 映射 |
| 文档归属 | `projects.user_id` | 从旧文档所属用户迁入 |
| `name` | `name` | 保留 1–120 字校验 |
| `goal` | `description`/`goal` | 统一为 Orialis 的项目目标字段，避免同时保留两个事实字段 |
| `startDate` | `start_date` | 日期映射 |
| `due` | `due` | 项目截止日期映射，不生成日程 |
| `color` | `color` | 保留为展示元数据；默认 `sage` 可兼容 |
| `status` | `status` | 保留 `active` 等已使用状态，并在 Orialis 契约中枚举化 |
| `nextActionTaskId` | `next_action_task_id` | 在任务 ID 映射完成且归属一致时迁移 |
| `createdAt`/`updatedAt` | 对应审计字段 | 初始化实体版本 |
| `milestones[]` | `project_milestones` | 拆表；补充 `project_id`、`position`、`version`、`deleted_at` |
| 里程碑 `id`/`title`/`due` | 同名字段 | 转 UUID、日期化、保留标题校验 |
| 里程碑 `completed`/`completedAt` | `completed`/`completed_at` | 保留完成语义 |

项目是任务的组织容器，不是日程。项目期限和里程碑期限均不自动进入 `calendar_events`。

### 4.4 课程/日程映射

旧数据没有独立的强类型 Course 表，课程对象和排课辅助对象都嵌在文档中。Orialis 第一阶段以 `calendar_events` 作为日程主表：

| Fangcun 来源 | Orialis 字段/处理 |
| --- | --- |
| `courses[].id` | 作为课程来源 ID；实际事件 ID 使用新的 UUID |
| `courses[].name` | `calendar_events.title` |
| `courses[].code`、`teacher`、`notes` | 合并或结构化到 `description`，以 Orialis API 契约为准 |
| `courses[].campus`、`location` | `location` |
| `courses[].day`、`weeks` | 与 `semester.startDate` 计算实际日期 |
| `courses[].startSection`、`endSection` | 通过 `timeSlots` 解析 `start_at`、`end_at` |
| `courses[].reminderMinutes` | `reminder_minutes` |
| `semester.startDate` | 课程周次展开的基准日期 |
| `timeSlots[].number/startTime/endTime` | 课程节次到时间段的解析表；结果写入开始/结束时间 |
| `courseExceptions[].type=cancel` | 不创建对应日程，或为已存在事件写软删除墓碑 |
| `courseExceptions[].targetDate` | 将发生日期改为目标日期，并保留原始 occurrence key |
| `courseExceptions[].startSection/endSection` | 覆盖本次发生的起止时间 |
| `calendarRules[].type=holiday` | 跳过命中的课程发生 |
| 旧 `local_key=course:<id>:<原始日期>` | 作为 `source_kind/source_id/occurrence_key` 的幂等来源键 |

课程的周次展开是 **ADAPT**：保留旧算法的可验证规则，但输出改成有明确起止时间的 `calendar_events`。日程必须能通过来源键幂等重建，避免重复导入。

### 4.5 同步映射

旧同步的 `revision` 是整份用户文档的版本，旧 `user_snapshots` 保存最近 30 份完整 JSON。Orialis 不把它直接当作实体版本：

| Fangcun | Orialis |
| --- | --- |
| `user_states.document` | 一次性导入输入/兼容快照，不作为主业务存储 |
| `user_states.revision` | 导入基线信息；不能替代实体 `version` 或用户同步游标 |
| `user_snapshots` | 可作为迁移前后恢复材料；新主流程使用快照接口和实体数据 |
| 整文档 `PUT` | 仅在未来兼容层考虑；Orialis 正式写入走实体命令 |
| `expectedRevision` | 迁移为实体 `base_version`；批量操作另有事务边界 |
| 无旧等价物 | 新建 `sync_events`，记录用户、游标、实体、操作、版本、幂等键和墓碑信息 |

建议的 `sync_events` 最小语义：每个用户的 `cursor` 单调递增；每次实体创建、更新、软删除各写一条事件；事件包含 `entity_type`、`entity_id`、`operation`、`version`、`mutation_id`、`created_at`，删除事件保留足够信息让客户端移除本地实体。客户端用 `after=<cursor>` 拉取，游标过旧时改走完整快照重建。

### 4.6 认证映射

| Fangcun | Orialis |
| --- | --- |
| `users.id` INTEGER | `users.id` UUID，优先 UUIDv7 |
| `username` | 保留唯一性和用户名校验 |
| `display_name` | 保留 |
| `password_record` | 改为明确的密码哈希字段/结构；可保留 scrypt 参数兼容已有账号 |
| `role`、`status` | 保留为认证与停用状态，但由 Orialis API 明确定义 |
| `user_sessions.token_hash` | 保留“只存 token hash”的安全边界，改为 UUID 外键和可撤销字段 |
| `Authorization: Session <token>` | 保留给客户端使用 |
| `fangcun_session` Cookie | 改为 Orialis 命名的 HttpOnly、Secure（HTTPS）Cookie |
| 30 天 Session | 默认保留；具体过期和撤销字段纳入 `user_sessions` |
| `Authorization: Bearer <Agent token>` | 暂不实现；Agent 属于后续阶段 |

旧的 owner/member 数据迁移逻辑是特定部署操作，不进入 Orialis 通用业务 API。若未来导入旧账号，必须先完成用户 ID、任务/项目/课程 ID 映射，再在单个事务中导入并记录结果。

## 5. 行为差异与 API 影响

| 主题 | Fangcun 行为 | Orialis 行为 |
| --- | --- | --- |
| 主存储 | 每用户一份 JSON 文档 | 任务、项目、里程碑、日程、同步事件分表 |
| 任务与日历 | 未完成任务可被 `local_events()` 投影为日历事件 | 任务永不因截止日期自动进入日历 |
| 课程 | 由文档中的课程、学期、节次即时展开 | 课程发生写入 `calendar_events`，使用来源键幂等 |
| 四象限 | 写入/返回 `quadrant`，由重要/紧急重新计算 | 只以 `important`/`urgent` 为事实，quadrant 派生 |
| 并发 | 整文档 `revision`，不一致返回 409 | 实体 `version` + `base_version`，事件游标独立递增 |
| 删除 | 完整文档中移除数组项；部分外部同步直接删除 | 软删除 + 同步墓碑；保留客户端可见的删除事件 |
| 重试 | 旧 Agent POST 没有幂等键，需人工读取确认 | 每个写入请求要求/支持 `mutation_id`，服务端去重 |
| 快照 | `user_snapshots` 保存整份旧文档 | 作为恢复/重建接口，不替代规范化实体存储 |
| 认证 | Fangcun 命名的 Session Cookie 和 Integer 用户 ID | Orialis 命名、UUID 用户、SQLx 会话表；Session 语义尽量兼容 |
| 外部日历 | Google/Outlook 与任务互相转换 | 当前不实现；未来只允许通过明确的日程 provider 适配层接入 |
| Agent | Bearer 令牌、限流、审计和任务/项目写入 | 当前不开放，不因旧文档列出就视为已迁移 |

## 6. 风险与控制措施

1. **冲突文件风险**：`rust-server/src/main.rs`、`docs/API-V1.md`、`docs/FLUTTER-SERVER-CHANNEL.md`、`docs/LINK-DATA-CONTRACT.md`、`rust-server/README.md` 含 Git 冲突标记。控制：不整文件复制；以函数行为和本迁移清单为准，后续逐项重写。
2. **整文档与规范化模型不一致**：旧数据所有关联都隐含在 JSON 数组中。控制：先建立旧 ID → UUID 映射，按用户事务导入；不允许跨用户 ID 关联。
3. **任务/日程语义漂移**：旧 `local_events()` 会把任务截止显示成日历事件。控制：导入保留字段但禁止自动创建日程；需人工分类的旧记录进入待审计清单。
4. **课程重复或错误日期**：周次、学期起点、调课和节假日组合可能造成重复或漏课。控制：用旧算法样例建立测试集；以稳定 occurrence key 做幂等；导入后统计原始课程数、生成事件数、取消数和跳过数。
5. **旧 ID 与 UUID 关联断裂**：任务的 `projectId`/`courseId` 可能指向缺失对象。控制：先导入父对象，失败关联置空并记录迁移警告，不伪造外键。
6. **时间和时区风险**：旧任务使用日期、字符串时间和服务器当前日期，循环任务没有每用户时区。控制：Orialis 统一时间类型和时区策略；循环任务在规格确定前不迁移为自动行为。
7. **版本语义混淆**：旧 `revision`、实体 `version`、同步 `cursor` 不是同一概念。控制：分别建模，API 响应分别命名，禁止用一个整数兼任三者。
8. **同步删除丢失**：旧数组删除没有事件，其他客户端无法知道删除发生。控制：Orialis 所有可同步实体使用 `deleted_at` 和墓碑事件，按保留期清理。
9. **密码兼容与安全**：旧 scrypt 记录是 JSON 字符串，字段格式与 Orialis 可能不同。控制：导入时验证参数和记录格式；新密码使用 Orialis 统一格式；迁移失败不降级为明文或弱哈希。
10. **外部 OAuth 扩张范围**：旧 `sync.rs` 已包含 Google/Outlook 连接，容易把当前服务端拖回第三方同步。控制：本阶段只记录为未来 provider adapter 需求，不迁移 token、OAuth 回调和远端写入。
11. **兼容 API 误导客户端**：旧文档把 Agent、穿戴和完整数据接口描述为已覆盖。控制：Orialis API 能力清单只发布当前已实现的 v1 资源，兼容接口单独标注为过渡能力。

## 7. 分阶段落地顺序

1. 固化本文档和 Orialis API/数据库契约。
2. 在 Orialis 中建立 SQLx migrations：`users`、`user_sessions`、`tasks`、`projects`、`project_milestones`、`calendar_events`、`sync_events`。
3. 先实现认证和任务/项目实体 CRUD；四象限只由重要/紧急字段派生。
4. 实现课程数据导入与日程事件生成，覆盖周次、节次、取消、调课和节假日测试。
5. 实现同步事件、游标、墓碑、`mutation_id` 和快照恢复。
6. 用一次性、可回滚的导入工具读取 `fangcun-backup` 数据；导入报告必须列出成功、跳过、冲突和需要人工处理的记录。
7. 本地验收通过后，再部署到 `orialis.jxcz.top`；Agent、网页和第三方日历另开阶段。

## 8. 本阶段明确不迁移的内容

- `user_states.document` 作为主存储的设计；
- 旧的完整文档覆盖写入作为 Orialis 正式同步协议；
- 任务到日历事件的自动投影；
- Google/Outlook OAuth、远端事件双向写入和第三方 token；
- Agent Bearer 令牌、限流、审计和自动化写入 API；
- `fangcun.link.v1`、手机/手环互联和 Vela 传输层；
- 网页静态资源、Flutter/Android UI 及任何与当前服务端基础无关的前端迁移。

