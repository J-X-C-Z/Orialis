# Orialis 手机端架构

手机端位于 `mobile/`，正式导航使用 `go_router` 的 `StatefulShellRoute.indexedStack`，固定为：

```text
/today  /events  /chat  /calendar  /profile
```

页面只发出用户意图；数据库、HTTP、同步和冲突逻辑位于 Repository/SyncEngine。V1 使用 Drift + SQLite，核心表包括 `tasks`、`calendar_events`、`messages` 和 `sync_metadata`。

本地写入先完成，再标记 `pendingCreate`、`pendingUpdate` 或 `pendingDelete`。Task 与 CalendarEvent 都使用客户端 UUID，因此断网创建后重新联网不需要替换本地 ID。

设计系统集中在 `lib/app/theme/app_theme.dart`。Today 参考 Fangcun 的信息层级，但 V1 只保留日期、到期事项、今日安排、完成状态和空状态。

Chat 首先写入本地 `messages` 表并立即显示，发送到服务端后再标记为 `synced`；当前只发送用户消息，不伪造 Agent 回复。

服务端地址通过 `ORIALIS_SERVER_URL` 构建参数注入；未提供时默认使用
`http://127.0.0.1:18443`，便于 Android 真机通过 `adb reverse` 做本地联调。例如生产构建使用：

```text
flutter build apk --release --dart-define=ORIALIS_SERVER_URL=https://orialis.jxcz.top
```

生产环境还需要接入正式 Session 登录；开发环境才使用 `X-Orialis-Device-Id` 设备认证。
