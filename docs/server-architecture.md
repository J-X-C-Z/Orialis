# Orialis Rust 服务端架构

服务端位于 `orialis-server/`，使用 Tokio、Axum、Serde、SQLx、SQLite 和 tracing。当前基础代码仍在逐步从 `main.rs` 拆分；本阶段包含健康检查、元信息、认证、Task、项目、CalendarEvent、Message 和增量同步接口。

数据库变更必须使用 `orialis-server/migrations/`。实体使用 UUID 字符串、UTC RFC3339 时间、乐观并发 `version` 和软删除 `deleted_at`。所有业务数据按用户隔离。

本地开发可设置 `ORIALIS_DEV_DEVICE_AUTH=true`，请求携带稳定的 `X-Orialis-Device-Id`，服务端会为该设备绑定开发用户。此模式仅用于本地开发，不是生产认证方案；正式环境继续使用 `Authorization: Session <token>`。

普通客户端 WebSocket 使用 `/api/v1/ws`（兼容别名 `/api/v1/mobile/ws`），只承担连接、heartbeat 和统一 envelope；Hermes Agent 通道仍使用 `/api/v1/agent/ws`。

## Agent Gateway 接入边界

Agent Gateway 在 HTTP Upgrade 阶段完成设备令牌校验。生产环境必须配置
`ORIALIS_AGENT_DEVICE_TOKEN`，插件使用 `ORIALIS_DEVICE_TOKEN` 通过
`Authorization: Bearer <token>` 发送；服务端不保存或打印明文令牌。开发环境
只有在服务端未配置令牌时允许无认证本地联调。
