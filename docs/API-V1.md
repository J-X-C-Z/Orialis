# 方寸 API v1

Rust 服务从 `/api/v1` 提供版本化入口。现有网页客户端仍使用 `/api`，因此旧路径继续保留，便于平滑升级；两套路径使用相同的请求体、响应体、Cookie 会话和错误格式。

## 当前覆盖

已迁移到 Rust 的 v1 资源包括。网页使用 HttpOnly Cookie；Flutter 使用登录响应中的 Session 令牌，两者最终映射到同一套服务端会话表：

- `GET /api/v1/health`
<<<<<<< HEAD
- `GET /api/v1/link/health`
- `GET /api/v1/link/snapshot`
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
- `GET /api/v1/auth/session`
- `POST /api/v1/auth/setup`
- `POST /api/v1/auth/register`
- `POST /api/v1/auth/login`
- `POST /api/v1/auth/logout`
- `POST /api/v1/auth/password`
- `DELETE /api/v1/auth/account`
- `GET|PUT /api/v1/data`
- `GET|POST|DELETE /api/v1/calendar/subscription`
- `GET /api/v1/admin/*`、`PUT /api/v1/admin/registration`、`PATCH /api/v1/admin/users/:id/status`
- `GET|POST|DELETE /api/v1/integrations/:provider/*`
<<<<<<< HEAD
- `/api/v1/agent/*`：令牌管理、审计、能力发现、日程读取、完整数据读写、任务和长期项目写入
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

`GET /api/v1` 返回服务版本和资源清单，可用于客户端启动时探测。日历订阅的公开 ICS 地址仍是 `/calendar/:token`，因为它不是 API 会话端点。

## 约束

<<<<<<< HEAD
v1 是 Rust 服务的版本化兼容入口；现有网页继续使用未版本化 `/api`，Agent 客户端可使用 `/api/v1/agent/*`，旧的 `/api/agent/*` 入口也保持兼容。Agent 写入沿用 `expectedRevision` 版本保护，令牌只存 hash，业务请求受限流和审计约束。
=======
v1 目前是已迁移核心 API 的版本化兼容入口，不代表 Node 端所有扩展能力已经迁移。Agent API（`/api/agent/*`）仍由现有 Node 服务实现，待完成令牌、审计、数据校验和任务/项目写入后再纳入 Rust v1；在此之前不应把 Rust 服务宣称为完整生产替代品。
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
