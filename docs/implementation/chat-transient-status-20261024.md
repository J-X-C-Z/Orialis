# 聊天临时工作状态（2026-10-24）

状态：本地实现与相关测试完成；尚未打包、安装或部署。

来源：用户要求将 `Working — 3 min…` 一类消息改为低透明度流光状态，隐藏 `Self-improvement review` 内部通知。实现位于 `codex/orialis-optimize-20261024`，基于 `719f51c`。

## 行为

- 聊天回复前只保留一条临时状态：正在思考、正在回复或等待处理；工作时长通知更新该行，不追加正文。
- 完成、失败、取消、停止、空闲或未知状态收起该行。审批与提问仍使用原有操作面板。
- 字体基础透明度 32%，流光高点 72%，线性循环使用 `LuminaMotion.standard * 8`。只有文字遮罩重绘；后台、不可见页面停止动画，系统减少动画时显示 45% 透明度静态文字。
- 历史中已保存的 Hermes 工作通知和后台复盘通知不显示为正文，也不作为会话列表预览。过滤后的分页仍能加载更早的正常回复。
- 用户消息、附件、普通回答和错误提示保留。历史过滤仅匹配 Hermes 已确认的 emoji 通知前缀；没有删除或迁移数据库记录。

## 转发原因与修正

本机 Hermes 的工作心跳为 `⏳ Working — <minutes> min…`，后台复盘为 `💾 Self-improvement review: …`，均携带 `non_conversational` 标记。原 Orialis adapter 在发送 `message.reply` 时丢失该区分。

`integrations/hermes/orialis/adapter.py` 现将带标记的工作心跳转为 `agent.status`，并接受但不转发后台复盘通知。附件和其他带标记消息仍走原有发送流程。现有工具进度已通过结构化工具事件传输，无须修改。

主要客户端文件：`chat_transcript.dart`、`chat_thinking_indicator.dart`、`agent_event_cards.dart`、`chat_page.dart`。

## 验证

- 新增状态、历史过滤、分页和现有活动状态测试：14 项通过。
- 聊天滚动、发送重试、审批、设备选择、富文本和状态页回归：26 项通过。
- Hermes adapter 测试：16 项通过，使用已安装 Hermes 的 Python 环境。
- 改动相关的 Flutter 静态检查无问题；diff 空白检查通过。
- 真机流光观感与应用安装未验收。原工作区和本工作区其他并行改动均保留。

测试覆盖记录分别在 `mobile/test/chat_transcript_test.dart`、`chat_thinking_indicator_test.dart`、`chat_transcript_history_test.dart` 和现有聊天测试中。
