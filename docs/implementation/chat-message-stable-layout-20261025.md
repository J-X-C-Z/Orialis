# 聊天发送状态固定布局 · 2026-10-25

用户验收目标：消息出现时即采用最终布局；发送中仅将最右侧状态箭头替换为旋转圆圈，避免气泡跳动。

实现范围为 mobile/lib/pages/chat/chat_page.dart 的 _MessageBubble：文字消息在 pending 与 synced 状态均使用相同 Wrap；时间与状态拆开，所有状态固定占用 12×12 槽位；复用 LuminaProgress（已有减少动态效果支持）。删除独立的「待发送 · 重试」行，待发送或失败时点击时间/状态即可重试，发送期间不允许重复点击。附件消息保留既有内容结构，底部元信息在状态切换时保持一致。

验证：flutter test test/lumina_chat_flow_test.dart test/agent_chat_ui_test.dart 通过；flutter analyze lib/pages/chat/chat_page.dart test/lumina_chat_flow_test.dart 无问题；针对首次发送的旋转圆圈、失败状态、重试与上传完成，以及短消息、长消息、手动换行的气泡尺寸/文字偏移进行了检查。

边界：本次按用户直接授权执行 coder assigned-task-paths 内的局部修改；保留工作树既有改动。外层 project.yaml/state.md/roadmap.md/memory/summary.md/memory.db 不存在，未伪造或恢复这些文件。共享记忆 recall 已完成。未打包、安装或做真机验收。
