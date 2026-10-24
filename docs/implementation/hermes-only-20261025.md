# Orialis Hermes 统一执行（2026-10-25）

状态：线上 Hermes 统一执行已完成；Mac、Azure、Windows、Hakari 四台设备均已通过公网实际回复验收。手机端仅更新源码，未构建或安装新包。

## 决定与范围

用户明确要求所有 Orialis Agent 执行由 Hermes 承接，停止使用 DSH。保留 Rust API、数据库、设备本地执行及各设备原有模型接入；本任务不将业务数据处理器改成聊天进程。架构决定见 `../decisions/ADR-hermes-only-20261025.md`。

项目管理文件在工作区有既有删除，按 Git HEAD 只读核对启动规则、项目状态、路线图和角色，没有恢复这些文件，也没有重新创建不存在的 memory.db。TASK-016/COORD-012 记录本次授权与跨界范围。主仓库 `repo/` 保留为权威文档位置；当前移动端开发副本 `repo-latest/` 只修改已授权的目标白名单和测试，没有覆盖并行延迟优化。

## 线上变化

- 账号默认设备保持 `JXCZ_AOZORA_Hermes`。
- 两个有效会话从 `JXCZ_HAKARI_DSH` 改绑 `JXCZ_HAKARI_Hermes`；一个旧 `JXCZ_AOZORA_Codex` 会话改绑 `JXCZ_AOZORA_Hermes`。
- 数据迁移前确认目标设备属于同一账号、受影响会话没有排队消息；事务只更新绑定和 version，既有 410 条消息数量不变，保留内容、附件、排序、标题和时间。原绑定保存在 Azure `/var/lib/oris/backups/hermes-only-20261025/bindings-before.json`，权限 600。恢复应按备份逐会话还原绑定，不能用旧整库覆盖新消息。
- Hakari 通过已核对身份的阿里云云助手检查：Hermes active/enabled，Orialis connected；DSH 进程不存在，DSH 服务入口不存在。旧 DSH/Codex 注册记录仅保留作历史记录，均离线。
- Windows Orialis profile 缺少模型名称及 provider，补齐为该设备主配置已有的 `gpt-6-luna` / `magpie`，保留 base_url、api_mode、认证及其他字段；新会话即时读取配置，不需要重启共享网关。备份 `C:\Users\Jxcz2\AppData\Local\hermes\profiles\orialis\config.yaml.backup-hermes-only-20261025T010721`。
- Hakari 原进程所有 HTTP 代理变量均指向 `127.0.0.1:7890`，没有 NO_PROXY；本机模型请求被代理返回 502。新增 `/etc/systemd/system/hermes-gateway.service.d/orialis-local-model.conf`，仅将 localhost/127.0.0.1/::1 绕过代理。重启仅影响 Hakari Orialis Hermes，重启前排队内容只有本任务验收消息，启动后读回确认两个 NO_PROXY 变量生效。
- Hakari 的 DeepSeek V4.1 拒绝 `agent.reasoning_effort: medium`；改为受支持的 high。模型名称和端口没有改变，修改前配置备份在 `/home/hermes/.hermes/backups/hermes-only-20261025/config.yaml.before`。

## 客户端源码

当前移动端副本 `repo-latest/mobile/lib/features/chat/data/agent_chat_service.dart`：Hakari 默认 ID 改为 `JXCZ_HAKARI_Hermes`；只接受四个已配置的精确 Hermes ID；即使通过构建配置传入 DSH ID 也拒绝。原 UI 调用的 `isDshTarget` 保留为返回 false 的兼容入口，避免改动正在并行开发的聊天页面。

手机新包未构建、安装或发布：本任务没有把其他尚未完成的移动端改动打包上线。旧手机包仍可能显示 DSH 槽位，需要随统一客户端更新生效。

## 验证

- 定向新增的 Hermes 路由/DSH override 排除测试通过；格式和差异空白检查通过。
- 整个 agent_chat_service_test.dart：23 项中 22 通过，既有并行延迟测试 `binding and presence reuse a connection until the session changes` 的连接端口数量断言失败（期望小于 3，实际 3），未修改该任务的实现或断言。
- 绑定迁移脚本自检通过：账号隔离、保留已删除会话、版本递增、重复执行无副作用、排队消息禁止迁移。实际事务确认消息数不变。
- 通过公网 API 新建隔离验收会话，绑定精确设备，发送唯一标记并回读 assistant 消息。Azure 18.55 秒、Mac 35.07 秒、Windows 4.68 秒均精确匹配。Hakari 会话 `hermes-only-59f393600f` 的精确回复 ID 为 `msg_7e649d24dd4a`，耗时 15.37 秒。最终注册列表的在线设备恰为四个 Hermes ID；账号有效会话的非 Hermes 绑定为零。
- 2026-10-25 01:27 CST 只读复核确认 Hakari 网关 active/enabled、`NRestarts=0`、DeepSeek 配置与 localhost 代理绕过仍生效；Hakari Hermes 在线且两个现有会话保持 Hermes 绑定。验收后检索到的 14 行网关日志中，502、timeout、ERROR 均为 0。
- 不以设备注册或本机状态文件代替实际回复。完整结构化验收在项目 `deliveries/hermes-only-20261025/acceptance.json`。九个本任务创建的测试会话已使用版本校验 API 软删除，不占用用户会话列表，底层测试消息仍留存用于审计。


---

## 先前阶段记录（完成前）

# Hakari Hermes-only migration — 2026-10-25

The Hakari Hermes Orialis gateway is configured as `JXCZ_HAKARI_Hermes` and runs as `hermes-gateway.service`. This is a runtime configuration change; the Hermes Orialis plugin already exists in the repository.

The Hakari Hermes migration passed an end-to-end acceptance on 2026-10-25 at 01:13 Asia/Shanghai. The synthetic Hakari conversation `hermes-only-59f393600f` produced the exact expected reply, persisted in Orialis as `msg_7e649d24dd4a`; the reply took 15.37 seconds. The acceptance record also confirms exact replies from Aozora, MBA, and PC Hermes, migrated conversation bindings, and cleanup of synthetic conversations.

The user chose to keep DeepSeek. Hermes uses `deepseek-flash` through `http://127.0.0.1:18777/v1` with `reasoning_effort=high`. Adding `localhost,127.0.0.1,::1` to both `NO_PROXY` and `no_proxy` fixed the local relay path. A read-only runtime check at 01:27 confirmed the gateway active/enabled, Hakari Hermes online, its two existing conversations bound to Hermes, and no 502, timeout, or ERROR entries in 14 post-acceptance journal lines.

The account-level `activeDeviceId` remains `JXCZ_AOZORA_Hermes`, preserving the user's existing default while Hakari-specific conversations use `JXCZ_HAKARI_Hermes`. `orialis-dsh-bridge.service` is currently not-found/inactive; its stop cause is unknown and this task did not attempt to restore it. The mobile source change awaits a separate client package build/install. See `../../deliveries/hermes-only-20261025/REPORT.md` for evidence and backup details.
