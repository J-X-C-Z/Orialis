# Orialis V1 架构

Orialis V1 是 Flutter 手机端、Rust 服务端和两端之间的 local-first 同步系统。

```text
Flutter UI → Riverpod → domain Repository / Controller → Drift / SQLite
                                      ↕
                                  SyncEngine ↔ HTTP
                                      ↕
                              Rust Axum → SQLx → SQLite
```

手机可以在没有服务器时启动、读取和修改本地数据。服务端是跨设备的权威状态，WebSocket 只负责 heartbeat 和变化提示，不作为唯一数据源。

`Task` 表示有截止日期的行动事项，`Schedule` 表示具有明确起止时间的日程；
`calendar_events` 仅是兼容性的存储/接口名称。Today 是二者的聚合读取视图，
只在查询层生成，不拥有独立数据库、实体或同步流。

## 手机端业务边界

页面只负责展示、输入和路由，不直接访问 Drift、HTTP 或 SyncEngine。业务边界如下：

| 页面 | 业务边界 | 说明 |
| --- | --- | --- |
| Today | `TaskRepository` + `ScheduleRepository` | Today Projection，合并读取 Task 与 Schedule |
| Events | `TaskRepository` | 只管理 Task，不创建 Schedule |
| Calendar | `ScheduleRepository` | 只管理 Schedule；底层 `calendar_events` 是兼容存储名 |
| Projects | `ProjectRepository` | Project、Milestone 与既有 `Task.projectId` 关联 |
| Chat | `ChatController` + `ChatRepository` | Controller 编排发送状态/重试，Repository 负责本地消息与会话 |

`EventRepository` 保留为旧调用方的兼容委托层，不再作为新领域逻辑的统一边界；新代码应直接依赖对应的 Task/Schedule Repository。同步和实时连接由应用层协调器负责，页面通过 Controller 或 Repository 触发，不持有网络细节。

Profile 中的服务器地址、登录和诊断操作属于基础设施设置例外，仍可通过 API client 读取配置；它不参与 Task、Schedule、Project 或 Chat 的业务读写。
