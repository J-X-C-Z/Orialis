# A03-07 Chat 服务端审计矩阵

| 能力 | 现有证据 | 结论 |
| --- | --- | --- |
| Conversation 列表/创建 | `GET/POST /api/v1/conversations`，按用户隔离，创建幂等返回既有对象 | 通过 |
| Conversation 重命名 | `PATCH /api/v1/conversations/{id}`，`baseVersion` 校验，重复成功请求可安全返回 | 通过 |
| 主会话保护 | `default` 自动创建且不可删除 | 通过 |
| Conversation 删除 | 软删除，用户归属和版本校验 | 通过 |
| Message 发送 | 先落库再异步投递 Hermes；支持客户端 ID 和附件 ID | 通过 |
| Message 查询 | 按 `created_at,id` 稳定分页；无分页参数保持旧数组响应 | 通过 |
| Hermes 回复 | 校验 `reply_to`、conversation、附件归属；助手消息幂等落库并通知手机 | 通过 |
| Attachment | 单文件 20 MiB、总计 48 MiB、最多 10 个；下载需要 Session 或短令牌，路径做 canonical 校验 | 通过 |
| Agent 交互 | Clarify、Approval、Tool、Artifact、Status、ACK/gap/resume 均有 Rust 协议定义和测试 | 通过 |
| 失败/重连 | delivery queue 持久化重试；Agent event 支持 seq 去重和 resume/replay | 通过 |

## 跨端未决项

Conversation 的创建、重命名、删除当前没有写入 `sync_events`，也没有对应的
`sync.change_hint`。因此手机端通过 Conversation API 主动刷新可以获得正确结果，
但不能仅依赖统一增量同步流发现会话变更。该问题涉及移动端 cursor 消费策略和事件
类型命名，需跨端单独决策后再改，不能在本审计中擅自新增事件。

Agent Gateway 的结构化事件仍以 `protocol/contracts/agent-gateway` 为 wire 契约；
本批不新增未来工具或字段。Message 与 Attachment 的 HTTP API 不改变 Agent wire。

验证：`cargo fmt --all`、`cargo test -p orialis-server`、Protocol 测试、
`git diff --check`。Contract validator 若缺少 `jsonschema` 依赖，记录为环境缺口。
