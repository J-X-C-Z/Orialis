# Orialis 插件端多设备契约盘点与迁移输入

状态：准备输入（未冻结、未实现）。本文件只记录仓库可验证基线和提案，不能作为 Node/Core 或 Control Plane 的实现承诺。

日期：2026-10-01
仓库：`projects/orialis/repo/`（唯一权威仓库）
基线：分支 `Lumina-UI`，`HEAD=bdc03801dd7fa6fbf417dd1254d8fbe12a62186a`；工作区已有大量未提交改动，包含 Hermes 插件源码和其他团队文件。本任务未改写这些源文件；文档为本任务新增。

## 1. 仓库与现状基线

| 边界 | 当前实现 | 来源 |
|---|---|---|
| Plugin | Hermes Orialis Python Gateway adapter，WebSocket Agent Gateway v1、HTTP 域工具、附件 metadata/HTTP 传输；明确无语音 | `integrations/hermes/orialis/README.md`、`plugin.yaml`、`protocol.py`、`tools.py` |
| MCP | 仓库未发现独立 MCP server/package、MCP tool registry 或 MCP manifest；不将 Hermes function tools 等同于 MCP | `rg --files` 仓库清单；搜索 `MCP`/`mcp` 只见文档零散说明 |
| Client SDK | 未发现独立可发布的 Orialis Client SDK 包。Flutter `mobile/` 内有 `OrialisApiClient`，属于应用内部客户端；Rust server 暴露 HTTP/WebSocket 接口 | `mobile/lib/core/network/orialis_api_client.dart`、`docs/api-v1.md` |
| 服务端 | Rust/Axum；Session 认证的 Task/Project/Milestone/Schedule/Conversation/Message APIs；`agent-devices` 只管理 Hermes 设备与消息投递选择 | `orialis-server/src/main.rs`、`docs/api-v1.md` |
| API 基线 | `/api/v1/capabilities` 当前列举服务 API 类别；它不是针对单设备的完整授权描述 | `orialis-server/src/health.rs`、`docs/api-v1.md` |
| Gateway | `hello` 注册 Hermes 设备；Agent capabilities hello/ack 协商 Gateway 事件与续传；和 HTTP API capabilities 是两套不同概念 | `protocol/agent-gateway/README.md`、`orialis-server/src/agent_gateway/protocol.rs` |

基线限定：`git status --short` 在开始时已显示大量既存修改/新增，当前 HEAD 只标识提交基线，不代表这些改动已提交或可由本任务归属。未运行代码测试；不以模拟实现或文档提案声称跨平台落地。

## 2. 指定方法现状与缺口

“现状”表示本仓库中可查到的路由/工具/Schema；“建议”是待 Node/Core、Control Plane、Security 与插件各方冻结的跨端契约。现有工作面向 Hermes 聊天 Gateway，不是本任务所需的通用节点控制平面。

| 方法 | 仓库现状和来源 | 缺口与建议 |
|---|---|---|
| `devices.list` | 部分近似：`GET /api/v1/agent/devices` 列当前用户 Hermes 设备、平台、在线状态和 active 标志（`main.rs`、`docs/api-v1.md` §7.4） | 定义通用受信任节点注册表；返回稳定 `deviceId`、状态、能力摘要、心跳与 `lastSeenAt`，分页且按调用者权限过滤。不要把在线状态当作可执行性保证。 |
| `devices.get` | 无通用单设备详情路由 | 建议 `GET /api/v1/devices/{deviceId}`；仅在当前主体获授权时暴露设备元数据和能力版本；未知/无权返回一致的 `NOT_FOUND` 或 `PERMISSION_DENIED` 语义（最终安全策略待定）。 |
| `devices.status` | Gateway 设备记录有 last-seen 和实时 online 判断；没有统一 status API/状态机 | 定义 `online / offline / revoked / unknown`，加 `observedAt`、租约/心跳新鲜度和 reason；客户端只能把 status 当观测值，执行时由节点再次校验。 |
| `files.list` | 无通用节点文件 API；现有 `/attachments` 是聊天附件 API，不是任意设备文件浏览 | 建议只列 capability 授权的虚拟根/工作区，相对路径、类型、大小、mtime、opaque file ID；默认不显示节点全盘。 |
| `files.search` | 无 | 建议在获授权的限定根目录内搜索；需定义分页、结果上限、忽略规则、符号链接处理、超时及审计，不支持任意 shell 搜索。 |
| `files.read` | 只有聊天附件上传/下载接口，不是节点本地文件读取 | 建议以 opaque `fileId` 或受约束 URI 读取，支持大小/类型限制和流式传输；凭 capability 校验路径边界，禁止路径穿越与未授权符号链接。 |
| `agents.list` | 有 `GET /api/v1/agent/devices` 的 Hermes 设备列表；没有通用安装 Agent 的目录/清单 | 定义安装 Agent 与设备的不同资源；`agents.list` 返回 agent identity、版本、状态、受支持 capability，不将 Hermes Gateway 工具或 Mobile 会话映射成通用 Agent。 |
| `agents.run` | 没有通用远程运行 API。Gateway 有消息投递、结构化 Agent 事件，但由 Hermes 负责执行，聊天 `message.send` 不能当任意任务执行入口 | 暂不开放执行；未来必须是带显式 `deviceId`、`agentId`、`requestId/idempotencyKey`、有界输入、审批票据的异步任务，先定义受限低风险动作；Terminal/任意代码执行默认关闭。 |
| `agents.status` | 有 Agent Gateway 事件与消息 ACK/回复状态，非通用 run 状态查询 | 定义 run 生命周期和查询 API，区分 `accepted/running/succeeded/failed/cancelled/unknown`；ACK 只表示接收，不表示完成。离线或事件丢失时由 query/resume 恢复。 |
| `capabilities.get` | `GET /api/v1/capabilities` 返回服务 API 类别；`capabilities.hello/ack` 在 Agent Gateway 协商事件及 resume（`health.rs`、Gateway README） | 分层定义 server、device、agent、subject grants 的 capability 清单；每项含稳定名称、版本、约束与风险级别。服务广告不构成用户授权，也不自动授予调用权。 |

本矩阵内没有 Mac/Windows/NAS 分叉 API。设备平台/运行时可作为 metadata，协议方法、字段和授权语义保持一致。

## 3. 跨端协议建议（待冻结）

### 3.1 方法与资源

- 维持一种版本化逻辑契约：统一 `devices.*`、`files.*`、`agents.*`、`capabilities.get` 方法。传输可由 Control Plane API 与节点连接层适配，但不能为 Mac、Windows、NAS 定义不同方法名或字段语义。
- 请求包含 `protocolVersion`、`requestId`、目标 `deviceId`（对设备操作必填）、调用主体/授权上下文；响应回显 `requestId`、`deviceId`、`observedAt` 和结构化结果/错误。
- `deviceId` 由注册服务签发为不透明、不可重用的标识（建议 UUIDv7）；不能编码用户名、主机名或操作系统。安装级身份与用户/account 绑定关系、换绑和重装规则须由 Node/Core 定义。现有 Hermes `<USER>_<DEVICE>_<Agent>` ID 仅作为迁移期 legacy ID 映射，不继续扩散为新通用 ID。
- 文件定位优先使用带授权上下文的 opaque `fileId`。需要 URI 时采用统一 `orialis://devices/{deviceId}/files/{opaqueFileId}`；禁止把任意绝对本地路径当 URI。URI 的解析、编码、根目录边界由 Node/Core 冻结。

### 3.2 Capability 与审批

- capability 使用命名空间（例如 `files.read`、`files.search`、`agents.run`），带版本、参数约束和风险级别。服务端广告能力、设备实际能力和用户授权 grant 分开呈现；调用要求三方交集且在执行前重验。
- 对每次调用有效的决策固定为 `allow / deny / ask`；来源包含 policy/用户/审批票据和过期时间。`deny` 终止；`ask` 返回 `APPROVAL_REQUIRED`、稳定 approval ID，获批后以同一 request/idempotency key 续行，不暗中重试/降级成 allow；无策略或控制面不可达按 deny/ask 安全失败。
- 本准备阶段不增加高风险写入能力。后续若有文件写入，须独立 `files.write` capability 和逐次审批；Terminal/任意命令执行默认关闭，不能以通用 `agents.run` 绕过。

### 3.3 错误、事件、离线与撤销

- 建议稳定错误码：`INVALID_ARGUMENT`、`UNAUTHENTICATED`、`PERMISSION_DENIED`、`APPROVAL_REQUIRED`、`NOT_FOUND`、`DEVICE_OFFLINE`、`CAPABILITY_UNAVAILABLE`、`CONFLICT`、`RATE_LIMITED`、`DEADLINE_EXCEEDED`、`CANCELLED`、`INTERNAL`。携带 `retryable`、安全可显示 `message`、`requestId`、可选 `details`；绝不回传 token、绝对路径或敏感文件内容。
- 事件 envelope 建议 `{protocolVersion,eventId,deviceId,sequence,occurredAt,type,requestId,payload}`；至少一次投递，消费者按 `eventId` 去重，按设备单调 `sequence` 检测 gap，并以 cursor/resume 恢复。`device.status_changed`、`agent.run.updated`、`approval.updated` 只通知变化，需 query 读权威状态。
- offline 时 `devices.status` 是观测快照；新 run 立即返回 `DEVICE_OFFLINE` 或明确排队状态（不得混淆）。排队时保留 request ID、过期时间和取消入口，恢复连接后重新校验 grant/capability，过期任务不可自动执行。
- 撤销通过主体/设备 grant 的 `revocationVersion` 或等价单调 epoch 传播；节点在执行前及长任务安全检查点重新验证。注销/断开/撤权须停止后续操作，已开始的读流/运行需按定义取消并发出终态。不能只依赖长缓存 TTL。

## 4. 迁移步骤及验收

1. **Node/Core 定契约**：共同确认身份生命周期、设备注册/心跳、文件根目录/URI、Agent 与 run model、错误码、Capability schema、审批和撤销语义；补齐威胁边界和持久化/队列需求。跨端实现前冻结版本与 schemas。
2. **Control Plane 接入**：实现统一方法、认证授权、审批、审计、事件续传和撤销传播；明确权限缺失时拒绝。只开放只读设备/文件元数据查询与 `capabilities.get`，写入/Terminal 保持关闭。
3. **节点适配器**：Mac、Windows、NAS 分别实现统一契约的 transport/OS adapter；逐平台验证真实文件根目录、权限和离线恢复。每个平台都须连真实 Node/Core 与 Control Plane，fixture/mock 只能测契约不能验收跨平台完成。
4. **插件端兼容层**：新增统一客户端调用和 schemas；保留现有 Hermes Gateway 消息、`agent-devices` 路由与旧 device ID 作为兼容映射。调用方能力探测后使用共同契约，缺失时明确返回 unsupported，不静默假成功。
5. **渐进迁移**：先 shadow/read-only 对比；再按 capability 显式启用设备状态/文件读取；观察错误率与审计；具备版本化撤销与回滚后再评审其他风险动作。删除 legacy 路由另行版本决策，本任务不授权删除。

### 可复现契约测试方案

- 固定一组 JSON Schema/OpenAPI fixtures，包含每个列举方法的合法请求/响应、未知字段、缺失 `deviceId`、权限 deny/ask、过期审批、撤销 epoch、离线设备、过期 run、错误码和事件 sequence gap。
- 跨语言验证：Rust Server/Node 与 Python Plugin、Dart Client 读取相同 fixture；验证字段名、nullable、分页游标、幂等重放和错误码一致。为每个 fixture 固定版本和 checksum。
- 负面安全用例：路径穿越、绝对路径/符号链接越权、大文件/超时、重放审批票据、撤权并发、设备 ID 冲突、重复/乱序事件。断言拒绝且无副作用。
- 端到端验证需要真实 Mac、Windows、NAS 节点与可用 Control Plane：列设备、状态离线转在线、授权根目录 list/search/read、读中撤权、断网/重连 cursor resume。没有真实节点和服务时只报告 contract conformance，不报告平台实现完成。
- 既有 `python scripts/validate-contracts.py` 和 Hermes 插件测试只验证现存 Orialis contracts，不覆盖本文新协议；新增 fixtures 后再纳入脚本/CI。此任务未执行测试。

## 5. 依赖、人员、资源和估时

估时为角色日（实现/验证工作日），在外部依赖未确认前为粗估；不代表承诺排期。

| 工作 | 责任 | 估时 | 依赖/资源缺口 |
|---|---|---:|---|
| 本次仓库盘点、协议输入、迁移和测试建议 | 插件端组长（本任务） | 1.5 日，已完成文档初稿 | 可查本地仓库；无独立 MCP/SDK 仓库材料 |
| 对本文做契约来源与兼容性复核 | 插件端开发组员（协议集成），Paperclip agent `5a56a151-882f-455a-8108-3d66f03cb6d5` | 0.5 日 | 可立即复核；不修改既存源文件 |
| 统一语义/Schema 冻结 | Node/Core owner + Control Plane owner；插件组参与 | 2–4 日 | 真实 schema/认证授权/设备身份 owner 尚未确认；parent ORI-47 多设备开发计划为上游依赖 |
| Node/Core 和 Control Plane 基础能力 | 对应 owning teams | 5–10 日以上 | 远程节点注册/连接/文件 adapter、策略/审批服务、撤销通道与审计均为真实缺项；需真实服务和目标节点 |
| Plugin 兼容客户端与 fixtures/CI | 插件端组员（实现）、插件端组长（复核） | 3–5 日 | **必须等待** ORI-47 统一协议冻结、Node/Core 与 Control Plane API/schema 可用；本任务不启动实现 |
| Mac/Windows/NAS 真实联调 | 对应平台组 + 插件组集成 | 每平台 2–4 日 | 三类真实节点、Control Plane 环境、测试账号/授权策略；不能用 mock 替代 |

插件组当前可指派成员：插件端开发组员（通用插件实现）、插件端开发组员（协议集成）；当前两位皆 idle。Node/Core 和 Control Plane 是跨组依赖，本组不代其创建或修改实现任务。建议由 ORI-47 owner 统一确定 blocker task/owners 和 schema freeze gate。

## 6. 本次核查范围与结论

- 已对照本仓库 Plugin、Server routes/capabilities、Gateway protocol、API 文档和移动端内部 client；没有发现 MCP server 或独立 SDK 仓库。
- 本文矩阵覆盖任务列出的全部 10 个 API 名称；每项均有仓库来源或明确的“未发现”结论与建议。
- 本次没有修改插件逻辑、Server、Node、Control Plane、权限策略或发布配置；没有将 mock、Hermes 消息工具或 Gateway 事件冒充通用多设备实现。
- 插件正式实现仍受 ORI-47 协议冻结及 Node/Core、Control Plane 就绪 gate 阻塞。建议部长复核协议输入及跨组依赖 owner 后，再分拆执行任务。
