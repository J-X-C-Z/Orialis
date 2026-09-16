# Oris

Oris（Orialis）从纯服务端基础开始建设。oris-refactor 只保留 Oris 自己的代码；方寸完整项目保存在 fangcun-backup 分支，后续按需抽取，不直接整体复制。

## 当前范围（第一轮）

- Rust workspace：oris-core + oris-server
- 纯 JSON API，无网页、PWA 和静态资源
- SQLite + SQLx migrations，默认使用 WAL
- 多用户注册、登录、Session（密码 scrypt 哈希，Session 只保存 token hash）
- 任务、项目、课程/日程的独立实体 API
- 版本控制、软删除墓碑和用户级增量同步事件
- 默认监听 127.0.0.1:18443
- 生产公网地址：https://orialis.jxcz.top

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
    GET/POST/PATCH/DELETE /api/v1/calendar-events
    GET /api/v1/sync/events?after=<cursor>&limit=<n>

任务只表达作业、项目行动和每日任务的截止信息，不自动进入日历；课程等有明确开始/结束时间的内容写入 calendar_events。

更新请求使用 baseVersion 做乐观并发控制，版本冲突返回 409。同步事件返回用户级递增 cursor，删除事件保留 tombstone。

## 本地运行

需要 Rust stable：

    cargo run -p oris-server

自定义配置：

    ORIS_HOST=127.0.0.1 +    ORIS_PORT=18443 +    ORIS_ENV=development +    ORIS_PUBLIC_URL=https://orialis.jxcz.top +    ORIS_DATABASE_URL=sqlite://./oris.db?mode=rwc +    cargo run -p oris-server

验证：

    curl http://127.0.0.1:18443/api/health
    curl http://127.0.0.1:18443/api/v1/meta

## 部署准备

服务器部署使用 deploy/oris.service、deploy/oris.env.example 和 Nginx 配置模板。生产数据库建议设置为：

    ORIS_DATABASE_URL=sqlite:///var/lib/oris/oris.db?mode=rwc

当前迭代暂不包含网页、Agent、Hermes、LLM、第三方日历连接和移动端功能。旧项目的迁移边界见 docs/fangcun-migration.md。
