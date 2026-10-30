# ADR: 原生统一账号登录

状态：已实现，2026-10-31。

用户要求统一登录不打开外部浏览器，进一步明确不使用 WebView。主应用与 News 使用共享原生账号/密码表单；身份服务要求时显示动态验证码。实际权限由原生确认弹窗展示并同意。

客户端通过官方 Authelia v4.39.28 的 firstfactor、TOTP、consent JSON API 推进 OIDC 事务，只在 HTTP 层接收明确允许的重定向，不加载 HTML。口令只发给固定 https://auth.jxcz.top，业务源站只接收原来的 OIDC start/callback/exchange/session 请求；两个短期内存 CookieJar 隔离。取消、超时和失败均不修改已保存账号。没有重开旧 Orialis 密码登录/注册接口。

原 Rust OIDC callback 继续负责签名、issuer、audience、nonce、PKCE 与已批准的原账号映射。客户端不按用户名猜测身份、不自行创建账号，不持有 OIDC client secret。原生登录不再监听本机回调端口，不需要 WebView2 或新的平台原生插件。

Authelia JSON API 取自官方前端当前使用的接口，升级身份服务时需要回归。原生表单支持密码与 TOTP；WebAuthn/passkey/Duo 未在本次实现，不能将它们当作已支持。保持身份服务的验证策略，不能绕过要求的因子。

参考：

- https://github.com/authelia/authelia/blob/v4.39.28/web/src/services/Password.ts
- https://github.com/authelia/authelia/blob/v4.39.28/web/src/services/OneTimePassword.ts
- https://github.com/authelia/authelia/blob/v4.39.28/web/src/services/ConsentOpenIDConnect.ts
- https://www.authelia.com/integration/guides/pam-authelia/

验证：定向服务/账号隔离测试、News账号相关测试、只用合成账号的真实 Authelia 原生 HTTP 授权与签名检查。真实身份服务测试模拟 Orialis API 一侧，不代表生产真实账号和原账号映射已重新完成端到端验收。最终详细结果见项目 deliveries/native-unified-login-20261031/REPORT.md。
