# A03-05 Schedule 审计矩阵

| 能力 | 服务端证据 | 结论 |
| --- | --- | --- |
| 查询 | `GET /api/v1/schedules` 与兼容路径 `/api/v1/calendar-events`；支持 `from`、`to`、`after`、`limit` | 通过 |
| 创建 | `POST /api/v1/schedules`；必填 `title/startAt/endAt`，默认 `allDay=false` | 通过 |
| 更新 | `PATCH /api/v1/schedules/{id}`；使用 `baseVersion` 乐观并发 | 通过 |
| 删除 | `DELETE /api/v1/schedules/{id}`；使用 `baseVersion`，写入 tombstone | 通过 |
| 字段 | `title`、`description`、`location`、`startAt`、`endAt`、`allDay`、`reminderMinutes`、`version`、`deletedAt` | 通过 |
| 时间边界 | 输入按 RFC 3339 解析；`startAt` 必须严格早于 `endAt`；查询区间为 `from <= startAt < to` | 通过 |
| 提醒 | `reminderMinutes` 为 nullable，且不能为负数 | 通过 |
| 分页 | 按 `startAt,id` 升序 keyset 分页，游标不透明且校验版本 | 通过 |
| 同步 | storage/API 兼容名为 `calendar_events`，sync wire entity 为 `calendar_event`；实体 version 与用户 cursor 分离 | 通过 |

Schedule 与 Task 严格分离：Schedule 没有 `completed`、`important`、`urgent`、`due`
或 `recurrence` 语义。Today 仍是 Task + Schedule 的查询层 Projection，不新增实体、
表或同步流。

验证证据：`cargo fmt --all`、`cargo test -p orialis-server`、
`git diff --check`。Contract validation 脚本已运行，但当前环境缺少 `jsonschema` 依赖，
因此该项需在安装 `scripts/requirements-contracts.txt` 后由 CI/发布门禁补跑。
