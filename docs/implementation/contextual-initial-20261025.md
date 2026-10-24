# Orialis 按内容自然首回应（2026-10-25）

TASK-019 的自然首回应已部署到四台 Hermes。最终一轮真实 Orialis API + 手机 WebSocket 验收四台全部通过；全部读回用户消息、首回应、完整回复及其关联关系。所有服务执行保持 Hermes，没有重新接入 DSH。

## 最终行为

普通用户消息开始处理后，插件通过 Hermes `orialis_initial_response` 辅助模型，结合消息文字与附件名称生成一两句自然回应，随后继续原有 Hermes 正文执行。附件输入仅含文件名，不声称已读取附件。首回应沿用 `message.reply` 与 `reply_followups`，完整回复另行持久化。

首回应使用 Westlake `deepseek-flash` 非思考模式，明确发送 `thinking=false` 与 `enable_thinking=false`；原有辅助模型链保留 Qwen 备用。拒绝包含思考内容或正数 reasoning_tokens 的辅助结果。四台最终缓存均确认 `mode=off`、实际 `model=deepseek-flash`、`reasoning_tokens=0`。独立端点探针同时验证了 DeepSeek 关闭思考，以及 `reasoning_effort=low` 启用思考。参数来源：[vLLM DeepSeek V4.1 Flash](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4.1-Flash)。

四台正文默认 `agent.reasoning_effort=low`。Windows 正文仍使用原来的 GPT-6 Luna / Magpie，首回应独立走 Westlake 别名；其余三台正文仍是原 DeepSeek 路由。主模型供应商未替换。Windows 既有 glm-5.3-flash low 覆盖保留。

辅助调用总等待预算 12 秒。网络故障、限流或超时才使用“我先看看你发来的内容，接着给你完整回复。”作为降级，不阻止正文继续。为避免 SDK 的同步初始化/网络锁冻结消息循环，同步辅助调用隔离到线程；超时后迟到的结果不能覆盖已缓存首回应。普通首回应仍是模型按内容生成，不保证每次措辞绝对不同，也不保证瞬时响应。

首回应内容与输入摘要保存在既有私有 AttachmentCache，0600 文件权限，沿用命名空间与保留期。确定性消息 ID 与保存后的内容保证同一输入在重复投递、重启后保持稳定。相同 ID 输入改变会拒绝复用。不保存思考过程、完整用户输入或附件下载地址。

## 最终验收

| 设备 | 首回应 | 完整回复 | 结果 |
| --- | ---: | ---: | --- |
| JXCZ_AOZORA_Hermes | 3.700 秒 | 16.359 秒 | 通过 |
| JXCZ_MBA_Hermes | 12.019 秒 | 62.052 秒 | 通过 |
| JXCZ_PC_Hermes | 0.922 秒 | 4.610 秒 | 通过 |
| JXCZ_HAKARI_Hermes | 4.012 秒 | 10.371 秒 | 通过 |

最终一轮四台均确认首回应匹配本次主题、先于最终回复、关联同一用户消息，且完成事件晚于真正最终回复。重复提交只保留一条首回应。Hakari 的自然首回应为：“好的，我来帮你整理下周兼顾复习与休息的学习计划。”

65 项插件测试通过，涵盖关闭思考参数、内容输入、附件名称、思考泄漏拒绝、降级、稳定缓存、相同 ID 输入变更、阻塞 SDK 不阻塞超时，以及生命周期/原生传输/重试/状态，以及启动暂存队列的完成/重放和事件身份判断。无需新客户端构建、协议或数据库结构变更。

最终数据库读回四组首回应与完整回复均仅一条、关联同一 anchor。12 个本任务合成测试会话已通过 API 软删除；临时登录会话剩余 0。保留原有个人数据及其他修改，未提交或推送。

## 排障与限制

初版 Hakari 两轮超时保留在 `live-probe.log`、`hakari-reprobe.log`，不能当作通过。py-spy 直接定位旧版异步辅助请求阻塞在 httpcore 连接池同步锁，主循环连 12 秒超时都无法执行。改用线程隔离后的阻塞超时测试及四台最终验收通过。helper 最终 SHA256：`1621bcdec01d083997b48dfe18fb66cb3bab27317ac49cfcbaa9ff8a697fae64`。

启动期 `hakari-thread-probe.log` 的提前完成已查明根因：Hermes `run_inbound` 在启动恢复期将同一事件放入 `_startup_restore_queue` 并返回 None；Base adapter 把 None 视为成功，稍后启动队列才重放真正正文。插件完成回调现在按事件对象身份检查队列；仍暂存时不释放 anchor/附件、不发送完成，重放后照常结束。已用两个生命周期测试覆盖。真实重启回归 `contextual-83b7deaddf` 已通过：自然首回应 → 真正完整回复 → 完成事件，重复提交仍只有一条首回应；此前错误完成不再出现。此次请求在服务停止/启动期间排队，首回应 90.733 秒、完整回复 170.109 秒。服务停止曾触发 systemd 超时，故重启窗口不能承诺即时回应；稳定运行延迟见上表。现有 Hermes 可能额外发送 home-channel 设置提示或旧版“✅”；本任务未清除此类独立提示。

配置与插件备份保留在各设备 profile 的 `backups/contextual-initial-20261025/`（线程修复前 helper 另有同目录备份）。启动时未恢复此前被删除的项目 project.yaml/state.md/roadmap.md/memory.db。当前用户指令取代 TASK-018 的固定句设计与当时不改模型设置的限制。

## 证据

`deliveries/contextual-initial-20261025/acceptance.json`、`final-live-probe.log`、`plugin-tests-startup-queue.log`、`final-readback.json`、四台 `*-model-evidence.json`、`*-config-final.json` 与线程部署记录。源码位于 `repo-latest/integrations/hermes/orialis/initial_response.py`、`adapter.py`、相关测试和 README。

最终 adapter SHA256：`69ae861065b939ed5a6dabb511214b6484f4562127c052b01a4ba18d5cc1fe50`。启动队列身份检查只修改 Orialis 插件，不改 Hermes core。

冷启动证据：`hakari-cold-regression.log`、`cold-final-readback.json`；四台最终 guard 部署/哈希见 `*-startup-guard.*`，helper 保持原验收版本。Hindsight 本次 recall 超时；总结 retain 已受理，异步持久化未确认。
