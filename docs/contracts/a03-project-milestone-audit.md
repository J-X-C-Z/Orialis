# A03-06 Project / Milestone 审计矩阵

| 能力 | 服务端证据 | 结论 |
| --- | --- | --- |
| Project 查询 | `GET /api/v1/projects`，支持 `status`、`limit`、`after`，按 `createdAt,id` 游标分页 | 通过 |
| Project 写入 | `POST /api/v1/projects`，校验名称、状态、日期和用户归属 | 通过 |
| Project 更新 | `PATCH /api/v1/projects/{id}`，nullable patch，要求 `baseVersion`，成功后 `version+1` | 通过 |
| Project 删除 | `DELETE /api/v1/projects/{id}`，软删除并写 project tombstone；所属未删除 Milestone 同步写 tombstone | 通过 |
| Milestone 查询 | `GET /api/v1/projects/{project_id}/milestones`，按 `position,id` 游标分页 | 通过 |
| Milestone 写入 | `POST /api/v1/projects/{project_id}/milestones`，项目归属校验，最多 100 项 | 通过 |
| Milestone 更新 | `PATCH .../milestones/{id}`，nullable patch，要求 `baseVersion`，成功后 `version+1` | 通过 |
| Milestone 删除 | `DELETE .../milestones/{id}`，软删除、版本递进并写 tombstone | 通过 |
| Task 关联 | `Task.projectId` nullable；创建/更新时校验项目归属和未删除状态 | 通过 |
| Next Action | `ProjectSummary.nextAction` 是查询结果中的完整 Task 对象；`nextActionTaskId` 只保存 Task ID 并校验同项目未删除，创建项目时必须为 null | 通过 |
| 数据关系 | ProjectSummary 通过关联查询统计 Task/Milestone，未复制存储 Task；Next Action 仅为投影 | 通过 |
| 同步 | Project 与 Milestone 分别写 `project` / `project_milestone` 事件，实体 version 与用户 cursor 分离 | 通过 |

Task 与 Milestone 都是有截止日期的事项，但 Milestone 从属于 Project；二者都不进入
Calendar Schedule。没有新增 Project/Milestone 共享 schema，本批不改变跨端 contract。

验证证据：`cargo fmt --all`、`cargo test -p orialis-server`、Protocol 测试、
`git diff --check`。Contract validator 若环境缺少 `jsonschema`，必须明确记录为环境缺口，
不能将其标记为通过。
