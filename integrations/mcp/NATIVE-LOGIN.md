# 原生客户端统一登录

手机和桌面使用 RFC 8252 系统浏览器登录与 IPv4 本机回调，无新增 Flutter 依赖。原生应用注册随机端口 `http://127.0.0.1:<port>/callback` 的公开 OAuth 客户端，明确请求 `orialis:session`。授权使用 S256 PKCE 与随机 state。

`orialis:session` 与 MCP 的 read/write 权限分开，不出现在公共 MCP 权限发现列表或默认范围中；只有单独请求此权限、且所有回调均为精确 IPv4 本机地址的公开客户端可以注册。用户在浏览器明确同意后，应用交换授权码，再调用 `GET /api/v1/auth/native/session` 获取自身 Orialis 会话。

会话交换会原子消费整个临时 OAuth 授权，拒绝重放；普通 MCP 令牌无法导出 Orialis Session。随后调用真实 Orialis 账号接口核对主体，响应禁止缓存。原生应用继续使用现有 Session API 与安全存储，取消或登录失败不会清除已有账号和本地内容。

反向代理必须将 `/api/v1/auth/native/session` 精确代理至 MCP 网关，保留该路径的访问日志关闭设置；现有 `/api/` 其余路径仍指向主服务。旧公网密码登录和注册接口保持关闭。

验证覆盖错误 state、PKCE、取消、超时、无效源站、并发消费、scope 隔离及会话身份检查。2026-10-31 实际 Flutter 代码已通过浏览器统一登录、本机回调、账号验证和临时会话注销验收。
