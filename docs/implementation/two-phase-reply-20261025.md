# Orialis 简短回应与完整回复（2026-10-25）

状态：四台 Hermes 已部署并通过公网 HTTP + 手机 WebSocket 同时验收。普通用户消息开始实际处理时，先收到“收到，我先处理一下。”，随后继续处理并发送完整结果。

## 行为与实现

- 在现有 `OrialisAdapter.on_processing_start` 生命周期中发送普通、可持久化的 `message.reply`；不调用模型生成这句话，也不将其写入模型的最终结果。初始消息 ID 根据会话和用户消息锚点确定，重复请求/重连不会新增一条相同回应。
- 初始回应只在协商 `reply_followups` 的服务端启用。旧服务端保持原有单回复路径。命令（含 `/stop`）、后台/定时输入不插入该回应。
- 完整回复、工具、附件、失败和取消沿用 Hermes 原有处理流程。首条回应不发 `agent.complete`。初始回复回执失败也不取消实际处理；明确的拒绝会使用同一个 ID 延迟 50ms 重试一次。普通超时不额外重试。
- 实测并发写入时，服务端曾因 SQLite `database is locked` 暂时拒绝一条初始消息。插件现在用错误中的 reply_to 立即结束对应回执等待，按上面的有限重试重新发送，不再空等整个回执超时。
- 某些 Hermes 版本在空原生流结束时把“✅”当作占位终帧。插件拒绝这个不明确的原生传输分支，让现有普通发送回退处理；不把该占位原生帧提前广播成完成。使用真实 GatewayStreamConsumer 测试确认：用户真正要求回答单个“✅”时仍正常送达。
- 某些旧 Hermes 的普通回退仍会保存“✅”，以及首次新会话的主频道设置提示；本次没有删除这些既有辅助消息，也没有修改 Hermes 核心或用户设置。四台验收均确认没有在实际完整答案到达前发出完成事件。

消息仍使用既有 Gateway v1 协议与数据库结构。服务端首条持久化回复会结束“消息已投递”的临时等待，但这不代表 Hermes 执行完成；后续回复按同一账号、会话、设备和用户消息锚点独立持久化。客户端运行状态由 Agent 生命周期事件决定，不由出现一条 assistant 消息推断。

## 源码与检查

当前统一发布代码副本 `repo-latest/`：

- `integrations/hermes/orialis/adapter.py`：初始回复、稳定 ID、回执错误匹配、有限重试和空原生终帧降级。
- `integrations/hermes/orialis/tests/test_initial_response.py`：顺序、持续运行、稳定 ID、命令/旧协议排除、回执超时/拒绝、有限重试、空流与真实单个勾号回答。
- `integrations/hermes/orialis/tests/test_native_transport.py`：已有真实后台 `/stop` 场景加入新的初始回应期望，保留原停止和最终状态断言。
- `mobile/test/chat_initial_response_test.dart`：普通中文回应可见，收到消息不完成任务，完整回复后终态正常。

插件相关 **52 项测试通过**；新增客户端 **2 项测试通过**；差异空白检查通过。既有服务端多回复提交/回执/幂等性测试在 TASK-017 的全量测试记录中通过，本任务没有修改 Rust 服务实现。没有新增依赖、数据库迁移或手机端实现改动，本功能无需单独打包手机应用。

## 线上部署

只替换四台当前已安装插件的 adapter.py，并在每次替换前确认空闲、保存副本、比对旧哈希和编译候选。最终 SHA256：`822eb33b0653fa483e918588690c70b4fb84e1d0c36fff7bc2cbbc6396bb6ab8`。

- Mac：`~/.hermes/profiles/orialis/runtime/orialis-plugin-20261025/adapter.py`；备份 `~/.hermes/profiles/orialis/backups/two-phase-20261025/`。重启单独的 Orialis profile 服务。
- Azure、Hakari：`/home/hermes/.hermes/plugins/platforms/orialis/adapter.py`；备份 `/home/hermes/.hermes/backups/two-phase-20261025/`；只重启各自 Hermes 服务。
- Windows：`AppData/Local/hermes/profiles/orialis/plugins/orialis-hermes/adapter.py`；同 profile 的 `backups/two-phase-20261025/` 保存副本。使用现有控制管道重载插件并只重启 Orialis profile；共享主机 PID 11064 保持不变，没有重启其他 profile。

源代码与其他会话的未提交修改、已删除管理文件保持原状。本次不恢复不存在的 project/state/memory.db，不覆盖 TASK-017 发布清单或归档包；集成交接说明在本交付目录，后续发布应取新源码，不能用旧归档覆盖当前插件。

## 实际验收

四设备在线，使用同一个公网账号的临时验证会话订阅真实手机 WebSocket；分别新建隔离聊天、绑定精确 Hermes 设备，再通过公网 API 发送唯一标记。

初始回应耗时：JXCZ_PC_Hermes 0.617 秒、JXCZ_AOZORA_Hermes 0.16 秒、JXCZ_HAKARI_Hermes 0.492 秒、JXCZ_MBA_Hermes 0.921 秒。

每台均确认：初始消息先于完整答案，初始和最终消息关联同一用户输入，完成事件在完整答案之后；重复 POST 仍只有一条初始回应。结束后再从生产数据库回读初始/最终消息各一条，内容与锚点准确。

结构化证据：项目 `deliveries/two-phase-reply-20261025/acceptance.json`、`live-probe-v2.log`、`final-readback.json`。第一轮调试记录不作为最终验收：它暴露了空流提前完成、短暂写入锁，以及验证脚本曾将含标记的用户消息错误识别为最终消息的问题；最终观察器已限定 assistant 角色，并重新通过全部四台验收。

临时认证 session 已删除；八个本任务生成的测试会话已按版本校验 API 软删除，保留底层验收消息用于审计。没有删除用户现有会话、账号或其他业务数据。
