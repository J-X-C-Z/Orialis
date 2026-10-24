# 聊天消息通知优化（2026-10-25）

状态：本地实现、测试和 Android 调试构建完成；未安装到真机。

来源：用户要求将系统消息通知的“新消息”标题改为会话内容总结，正文显示精简提要，自己发送的消息不再产生系统弹窗。

## 实现

- 通知控制器和 Android 原生入口均只接受明确的 `assistant` 角色；`user`、缺失角色和其他角色不弹通知。聊天消息的入库与同步保持原流程。
- 工作心跳、内部复盘以及 `memory-` / `event-` 后台会话不触发系统通知。
- 本地抽取标题：优先使用回复中的有效主题标题，其次使用该回复对应的用户提问，再回退到有效会话名称和回复内容。标题不超过 26 个 grapheme；不是额外调用模型生成。
- 正文提取前两条简短内容，去掉 Markdown、链接地址、代码块和纯寒暄，不超过 100 个 grapheme。结构化回复使用其已提供的纯文本 fallback；仅含代码、附件时提供对应简短提示。
- 提问上下文优先按 `replyToMessageId` 匹配，否则查询不晚于回复 `createdAt` 的最近提问，避免延迟回复引用下一轮问题。
- 保持通知的会话分组、账号隔离、去重和通知点击进入对应会话；异步读取摘要上下文后重新检查启用状态与身份 generation。
- 设置页的手动测试选取最新可见助手回复，用实际内容生成通知，并明确传递助手角色。

## 文件

- `mobile/lib/features/system_integration/chat_notification_summary.dart`
- `mobile/lib/features/system_integration/system_integration_controller.dart`
- `mobile/lib/pages/profile/system_settings_page.dart`
- `mobile/android/app/src/main/kotlin/top/jxcz/orialis/SystemBridge.kt`
- `mobile/NOTIFICATIONS.md`

## 验证

- `chat_notification_summary_test`、`chat_notifications_test`、既有 `system_integration_test`、`sync_coordinator_test`：25 项测试通过。
- 相关 Dart 静态检查无问题，diff 空白检查通过。
- `flutter build apk --debug --no-pub -v` 成功；编译的原生字节码确认包含助手角色检查。
- 调试包：`mobile/build/app/outputs/flutter-apk/app-debug.apk`。未执行真机通知弹出、点击或覆盖安装验收。

本次只修改上述通知相关文件和对应测试；同一工作区其他并行改动保留。

## 通知点击行为修订

来源：用户 2026-10-25 明确要求，系统聊天通知点击后进入相应对话最底部，无需高亮消息。

- 通知路由保留 conversationId/messageId 参数和设备目标校验，打开后直接复用会话的最新内容滚动逻辑。
- 移除通知入口对原消息的高亮和历史定位；打开会话时清空待执行的旧消息定位。引用消息点击仍使用原有定位/高亮功能。
- 回归用例使用 80 条消息，覆盖通知指向已在初始窗口之外的旧消息，以及用户向上滚动后点击另一条通知；验证最终位置在底部且无高亮。

本次验证：相关页面与回归测试静态检查通过；diff 空白检查通过。回归测试两次均在加载阶段被当前 `core/sync/sync_engine.dart` 的编译错误阻塞（如 `_pushCalendarEvents` / `mutationIdFor` 未定义），尚未实际执行；未修改该同步模块、未构建安装新包或进行真机验收。
