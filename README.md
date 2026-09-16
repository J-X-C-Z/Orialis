# Orialis

Orialis 从纯服务端基础开始建设。`orialis-refactor` 只保留 Orialis 自己的代码；方寸完整项目保存在 `fangcun-backup` 分支，后续按需抽取，不直接整体复制。

## 当前范围（第一轮）

- Rust workspace：orialis-core + orialis-server
- 纯 JSON API，无网页、PWA 和静态资源
- SQLite + SQLx migrations，默认使用 WAL
- 多用户注册、登录、Session（密码 scrypt 哈希，Session 只保存 token hash）
- 任务、项目、课程/日程的独立实体 API
- 版本控制、软删除墓碑和用户级增量同步事件
- 默认监听 127.0.0.1:18443
- 生产公网地址：https://orialis.jxcz.top
- Flutter Android 优先客户端：mobile/

API：

    GET /api/health
    GET /api/v1/health
    GET /api/v1/meta
    GET /api/v1/capabilities
    POST /api/v1/auth/register
    POST /api/v1/auth/login
    POST /api/v1/auth/logout
    GET /api/v1/auth/session
    GET/POST/PATCH/DELETE /api/v1/tasks
    GET/POST/PATCH/DELETE /api/v1/projects
    GET/POST/PATCH/DELETE /api/v1/projects/{project_id}/milestones
    GET/POST/PATCH/DELETE /api/v1/calendar-events
    GET/POST /api/v1/conversations/{conversation_id}/messages
    GET /api/v1/sync/events?after=<cursor>&limit=<n>
    GET /api/v1/sync/snapshot
    GET /api/v1/ws                    # mobile heartbeat/change channel
    GET /api/v1/mobile/ws             # compatible alias
    GET /api/v1/agent/ws
    POST /api/v1/agent/debug/message  # development only

任务只表达作业、项目行动和每日任务的截止信息，不自动进入日历；课程等有明确开始/结束时间的内容写入 calendar_events。

更新请求使用 baseVersion 做乐观并发控制，版本冲突返回 409。同步事件返回用户级递增 cursor，删除事件保留 tombstone。

Agent Track（M0–M5）已落地：服务器提供 WebSocket Agent Gateway、开发触发器、ACK、去重和自动重连；Hermes 插件源代码位于 `integrations/hermes/orialis/`，本机插件目录为 `~/.hermes/plugins/orialis/`。

生产接入时，在服务端设置 `ORIALIS_AGENT_DEVICE_TOKEN`，并在 Hermes 插件设置对应的 `ORIALIS_DEVICE_TOKEN`；插件会通过 `Authorization: Bearer` 发送令牌。开发环境未配置服务端令牌时允许本地无认证联调。

## 本地运行

需要 Rust stable：

    cargo run -p orialis-server

自定义配置：

    ORIALIS_HOST=127.0.0.1 \
    ORIALIS_PORT=18443 \
    ORIALIS_ENV=development \
    ORIALIS_PUBLIC_URL=https://orialis.jxcz.top \
    ORIALIS_DATABASE_URL=sqlite://./orialis.db?mode=rwc \
    cargo run -p orialis-server

验证：

    curl http://127.0.0.1:18443/api/health
    curl http://127.0.0.1:18443/api/v1/meta

## 部署准备

服务器部署使用 deploy/orialis.service、deploy/orialis.env.example 和 Nginx 配置模板。生产数据库建议设置为：

    ORIALIS_DATABASE_URL=sqlite:///var/lib/orialis/orialis.db?mode=rwc

当前迭代暂不包含网页、LLM 和第三方日历连接。手机端第一阶段边界见 docs/architecture.md、docs/mobile-architecture.md 和 docs/sync.md；旧项目的迁移边界见 docs/fangcun-migration.md。
