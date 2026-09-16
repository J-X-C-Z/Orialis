# Orialis 手机端架构

手机端位于 `mobile/`，正式导航使用 `go_router` 的 `StatefulShellRoute.indexedStack`，固定为：

```text
/today  /events  /chat  /calendar  /profile
```

页面只发出用户意图；数据库、HTTP、同步和冲突逻辑位于 Repository/SyncEngine。V1 使用 Drift + SQLite，核心表包括 `tasks`、`calendar_events`、`conversations`、`messages` 和 `sync_metadata`。`calendar_events` 是旧存储表名，领域层统一称为 Schedule；它与 Task 保持独立。

本地写入先完成，再标记 `pendingCreate`、`pendingUpdate` 或 `pendingDelete`。Task、Schedule 与 Conversation 都使用客户端 UUID，因此断网创建后重新联网不需要替换本地 ID。

设计层集中在 `lib/app/design/`：`design_tokens.dart` 管理品牌颜色、间距、圆角和尺寸，
`app_theme.dart` 管理 Material 主题，`design_components.dart` 管理跨页面公共视觉组件。
页面只组合这些设计资源，不把业务状态放进设计层。Today 参考 Fangcun 的信息层级，
但 V1 只保留日期、到期事项、今日安排、完成状态和空状态。

Chat 首先写入本地 `messages` 表并立即显示，发送到服务端后再标记为 `synced`；会话列表来自独立的 `conversations` 表，主会话不可删除。聊天支持文本、文件、相册照片和拍照；附件先上传到服务端，再随消息投递给 Hermes，回复通过实时通道写回本地消息库。

服务端地址通过 `ORIALIS_SERVER_URL` 构建参数注入；未提供时默认使用正式地址
`https://orialis.jxcz.top`。本地联调时可显式覆盖为
`http://127.0.0.1:18443`，再通过 `adb reverse` 连接本机服务。例如生产构建使用：

```text
flutter build apk --release --dart-define=ORIALIS_SERVER_URL=https://orialis.jxcz.top
```

手机端已接入正式 Session 注册、登录、会话恢复和退出登录；Session 令牌使用
Android 平台安全存储。开发环境才使用 `X-Orialis-Device-Id` 设备认证。
