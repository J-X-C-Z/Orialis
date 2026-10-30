# Orialis 2026-10-31 整合版本

来源：保留 ui-neumorphic 主工作树未提交更新，单独冻结发布；合并 repo-latest 云端记忆、真实生产 OIDC、已验证 Hermes 四模块、MCP 0.2.0 和 Web 自动同步。原工作树未重置、未清理。

客户端包含原生统一账号表单、聊天符号/自动命名/日程快捷入口、连续交互动效、日/周/月视图、原生日历同步、手动日程跟踪、记忆 IntelligentUI、跨设备云同步、手环连接恢复与自动同步、Mac 记忆快捷键。上传策略以最新用户指令为准：本机保留原图，云端保存压缩副本。

服务端保留现行统一账号映射与26类响应UI能力；已有迁移0至21字节不变，新增0022统一记忆存储；图片、记录、MCP文字编辑共用账号隔离和版本链，不启用已废弃的临时纯文本客户端增量。

Web 保留线上统一账号登录/绑定/OIDC交换，同时加入前台自动刷新、编辑保护和账号切换隔离。Hermes保留自动命名、视频重点摘要及凭据scope修复，更新日期时段规则与记忆UI提示。MCP扩展到19工具，记忆修改要求memory:read和memory:write并校验baseVersion/changeReason；旧连接需重新明确授权。

Android沿用正式包名top.jxcz.orialis及既有签名；开发环境使用Java17，发布源码不固定本机Java绝对路径。Mac本机主App为ad-hoc签名；完整WidgetKit扩展仍需开发证书和App Group授权。Windows共用源码包含在整合中，未在本次macOS环境构建安装；Android系统小组件仍为设计交付。

验收及回滚以外部 deliveries/integrated-release-20261031/REPORT.md、各组件报告、签名/哈希和真实服务读回为准。手机与手环未连接，安装、OEM通知显示、长时后台/断网恢复与历史手机图片补传不因此视为通过。
