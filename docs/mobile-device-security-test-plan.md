# Orialis 手机端多设备安全测试设计

状态：测试设计稿；ORI-64 已由开发部长复核通过并交回 ORI-62；不是实现验收报告。
基准：`protocol/contracts/multidevice-v1`，契约版本 1.0.0 / wire major 1，冻结日期 2026-10-01。
范围：手机端 Device Center 与 Node/Control 的安全联调设计；不改协议字段/语义、服务端或手机功能代码。

## 当前事实与边界

- 契约定义 Node 配对、单次配对秘密、用户 Session、设备凭据、account/device 所有权、能力与 grant、事件游标、租约和撤销语义。
- 仓库验证记录 `docs/multidevice-contract-v1-verification.md` 记载：生产 `/api/v1/capabilities` 未广告 `multidevice.v1`，`GET /api/v1/nodes` 返回 404；本地未发现 Node/Control 服务。契约冻结不等于部署或实现。
- `protocol/contracts/fixtures/` 中 Device/Event/URI fixture 只验证序列化形状。它们不是已配对节点、真实认证、跨手机端到端、权限执行或撤销传播证据。
- 本计划不测试 arbitrary file access、shell、Agent 执行、文件读写等契约 v1 范围外能力；也不把现有 Hermes `agent-devices` 或 Gateway heartbeat 当作通用 Node 实现。

## 威胁模型

| 威胁 | 资产/信任边界 | 主要控制（按冻结契约） | 测试关注 |
|---|---|---|---|
| 冒充节点/用户 | 用户身份、账户节点清单、配对信任 | 已登录用户发起并确认目标端显示的一次性代码；5 分钟到期、单次使用、限速；每请求验证 Session 与账户归属 | 错误账户确认、猜码/过期/重复兑换、伪造 deviceId 或身份字段均拒绝 |
| 重放 | 配对秘密、认证请求、事件/游标、操作批准 | 配对秘密一次性；事件含 eventId/sequence/opaque cursor；授权在执行前复验；approval `ask` 必须同一请求获批后恢复 | 重放兑换/旧凭据/旧批准/重复事件不产生第二次绑定或操作；契约未规定所有 HTTP 请求 nonce/idempotency，见假设 |
| Token 泄露或滥用 | Session 与 Node credential | Session hash-only；Node credential 一次返回、设备范围、不可充当用户 Session；过期/撤销立即拒绝；错误和日志不含秘密 | 存储、日志、崩溃/网络诊断、备份及剪贴板/截图检查；凭证跨设备使用拒绝 |
| 权限绕过 | 高风险 capability、grant、审批 | 服务支持、账户归属、设备能力、未过期显式 grant 全部满足；缺策略 fail-closed；能力广告不等同授权；ask 未获批不执行 | 修改客户端 grant/UI、伪造能力、过期 grant、拒绝/未配置 grant、未批准恢复路径均不能触发副作用 |
| 跨 Node / 跨账户隔离 | 节点元数据、心跳、能力、事件、撤销状态 | 每次请求校验 authenticated account + deviceId；只返回该账户节点；Node credential 限定自身 | A/B 账户与设备交叉读写、猜测 opaque ID、cursor 混用、node credential 冒用另一节点都拒绝且无数据泄露 |
| 手机丢失后的撤销 | 丢失手机 Session、配对 Node credential、已连接节点 | 手机注销撤销当前 Session；Control 删除节点原子递增 revocationVersion；推送 `node.revoked` 尽力而为，但服务端每次请求强制检查；重连旧凭证失败 | 在线/离线丢失手机场景；推送丢失仍拒绝旧版本；恢复后须重新配对；在安全检查点停止进行中工作 |

## A–G 用例

以下用例必须在 Node/Control 实现可用、且服务端能力显式广告 `multidevice.v1` 后执行。表中“证据”是执行时需要采集的材料；当前没有实测结果。先用隔离测试账户及无敏感数据的节点。

### A. 配对冒充、过期与重复兑换

- **前置条件：** 两个测试账户 A/B；Android 或 iOS 已登录 A；受测 Node 显示配对码；服务端支持 v1、可查审计日志。
- **步骤：** 在 B 会话尝试确认 A 发起的 pairingId；用错误码/过期码完成兑换；对有效码完成一次后再次兑换；尝试替换请求中的 accountId/deviceId。
- **预期结果：** 只有 A 明确确认目标 Node 的有效单次秘密才完成绑定；秘密过期（5 分钟）、错误账户、重放及客户端指定身份均被拒绝；没有第二个节点凭证发放。
- **证据：** 脱敏请求/响应、服务端 requestId 与审计事件、节点列表前后对比、确认界面与 Node 显示码的人工对应记录。
- **边界：** 若契约实现未将“确认”绑定到具体 Node 或配对码展示流程，记为契约/实现待澄清，不自行推断字段。

### B. 配对、请求与事件重放

- **前置条件：** A 用例成功建立的隔离测试节点；可重复发送已捕获的脱敏请求与事件。
- **步骤：** 重放 pairing complete；用撤销前保存的 Node credential 重放 heartbeat；重复投递相同 eventId/sequence；在审批后重放同一 approval/resume 请求。
- **预期结果：** 配对秘密仅兑换一次；已撤销凭据不续租；重复事件按 eventId/sequence 去重且不重复触发效果；批准不能授权不同请求或重放出额外执行。
- **证据：** 请求 requestId、eventId/sequence、去重前后状态、节点心跳/副作用计数与服务日志（秘密全部脱敏）。
- **边界：** v1 未声明通用 HTTP nonce、所有操作的幂等键或精确事件去重窗口；需协议组确认由 eventId/sequence、业务幂等或传输层中的哪一层保证。

### C. Session / Node token 泄露与滥用

- **前置条件：** 测试 Session 和 Node credential；可检查客户端安全存储、服务端凭证存储与受控日志。
- **步骤：** 检查应用存储、备份/诊断/崩溃日志中是否出现明文；尝试把 Node credential 用作 `Authorization: Session`；将节点 X 凭证用于节点 Y；登出后重用 Session；过期后重用凭证。
- **预期结果：** 服务端只存 Session hash；Node credential 不能获得用户 Session 权限且只能用于契约准许的自身操作；登出、到期和撤销后请求立即失败；任何日志/错误均不返回 token。
- **证据：** 安全存储检查记录、服务端脱敏存储核对、登出/到期拒绝响应、日志扫描结果、跨节点拒绝响应。
- **边界：** 应用商店签名、平台备份策略、Keychain/Android Keystore 行为需按具体构建配置实测；fixture 不提供凭证保护证据。

### D. 能力/权限绕过与审批

- **前置条件：** Node 暴露一个可安全验证的测试 capability（无真实数据副作用），具备 allow/deny/ask/unconfigured 及过期 grant 测试数据；有权限审计。
- **步骤：** 分别尝试无服务端广告、不可用能力、deny、unconfigured、过期 grant；篡改手机 UI/请求声称 allow；对 ask 不批准直接执行，再批准后恢复原请求；尝试把批准挪用于另一 requestId。
- **预期结果：** 全部组合按契约 fail-closed；ask 返回 `APPROVAL_REQUIRED` 且无副作用；仅原请求取得明确批准后可继续；能力可用状态不单独授予权限。
- **证据：** 每种矩阵组合的响应错误码、requestId、批准记录、Node 执行计数/审计轨迹。
- **边界：** v1 只冻结授权语义，不定义所有 capability 名称、批准者 UI 或批准凭证的具体载荷；未冻结部分由协议组明确。

### E. 跨 Node / 跨账户隔离

- **前置条件：** 测试账户 A/B 各有两个节点；节点与事件均为合成数据；可查看访问审计。
- **步骤：** 以 A 读取/删除 B 节点；用 A 的 node credential 读取 B 的能力、发心跳或访问 B 事件；交换账户游标；猜测/替换 deviceId 与 accountId；并发执行列表分页和撤销。
- **预期结果：** 账户与设备范围逐请求核验；不得返回 B 的存在细节或数据；节点 credential 只能更新自身租约或读取自身允许配置；游标不得跨账户泄漏；分页/撤销无越权窗口。
- **证据：** 每个角色矩阵的 HTTP 状态/稳定错误码、响应体脱敏 diff、服务审计 principal/account/device 与请求 ID。
- **边界：** 是否以 403 或 404 隐藏资源存在性须遵循实现所选稳定策略；目前契约只列 `PERMISSION_DENIED`/`NOT_FOUND`，需一致性确认。

### F. 丢失手机、登出及设备撤销

- **前置条件：** 手机 M 登录 A，A 账户有 Node N；准备一部控制端设备 C；可阻断推送/断网并查看 revocationVersion。
- **步骤：** 从 C 撤销 N；分别在 N 在线、离线和断网期间执行；模拟撤销事件丢失，恢复网络后用旧 credential 心跳/请求；从 M 登出并重用该 Session；检查另一台仍有效登录手机的 Session。
- **预期结果：** 删除幂等并原子递增版本；撤销优先于 online；Control 对旧版本每次拒绝，推送不是唯一防线；恢复旧节点需重新配对；登出只撤销该 Session，其他有效 Session 按契约仍可用；进行中工作在安全检查点停止。
- **证据：** 撤销前后版本和状态、事件 delivery/故意丢失记录、重连拒绝响应、Session 分别验证结果、Node 停止执行时间线。
- **边界：** 推送尽力而为，不以“收到 node.revoked”作为撤销成功的唯一标准；v1 未定义安全检查点最长时延，标记为待确认。

### G. 会话边界、能力广告与失败关闭

- **前置条件：** 一台未配对测试手机、一台已配对测试设备；支持 v1 的目标环境和当前生产只读环境各一套。
- **步骤：** 对照不同 Session（有效、过期、已登出）、未配对设备与能力广告状态执行列表、详情、配对及节点操作；生产环境检查能力发现与 `/nodes` 路由，不提交任何有副作用请求。
- **预期结果：** 未认证/过期/已登出 Session 被拒；客户端仅在 capabilities 明确广告 `multidevice.v1` 后启用功能；未配对端不能读写节点；不支持环境不推断支持、不回退到 Hermes `agent-devices`；无授权状态 fail-closed。
- **证据：** 脱敏能力响应、客户端发现行为录屏、生产只读状态码与时间戳、支持环境错误码和审计记录。
- **边界：** 当前生产已知无能力广告且 `/nodes` 404，这只能作为“不具备当前服务端验收条件”的证据，不能算 G 用例通过。

## 真机测试环境清单

开始任何配对或授权用例前逐项登记；缺少 Node/Control 实现或能力广告时，只完成客户端负向/发现行为检查，不执行伪造 E2E。

- [ ] Android 真机：型号、Android 版本/API、Orialis build/version、安装来源、签名指纹、网络类型、日期时间/时区、系统安全补丁。
- [ ] iOS 真机：型号、iOS 版本、Orialis build/version、签名/Team、安装来源、网络类型、日期时间/时区、系统安全补丁。
- [ ] 至少两个专用测试账户 A/B；记录授权人员与清理责任人；无生产个人数据、真实文件或真实高风险 capability。
- [ ] Node 测试端：平台/型号、Node/Core 版本和 commit、credential 存储方式、支持的 protocolVersion、能力清单；与 Control Plane 测试环境版本一并记录。
- [ ] Control Plane：部署版本/commit、数据库迁移版本、`/api/v1/capabilities` 明确含 `multidevice.v1`、TLS 证书链、服务器时钟、限速/审计配置；核实 `/nodes` API 确实是对应实现。
- [ ] 网络与观测：独立测试网络；可控断网/延迟/重放；客户端日志、Control/Node 日志和审计按统一 UTC 时间关联 requestId；任何 token、配对秘密、个人数据在导出前脱敏。
- [ ] 账号与设备隔离：测试环境与生产完全分开；为每轮用例创建唯一 pairing；禁止共享真实账户、生产 Node credential 或截图中的有效验证码。
- [ ] 清理：撤销所有测试 Node 与测试 Session；清除一次性 pairing、设备 credential、应用安全存储、下载/诊断文件和测试数据；确认撤销版本已生效；保留脱敏日志、版本和清理记录。
- [ ] 复测记录：逐用例记录开始/结束 UTC、操作者、手机/Node/Control 版本、前置状态、步骤、结果、证据路径、异常与清理结果；失败不得用 fixture 或模拟响应替代。

## 待协调假设与可执行待办

以下项目不改变 1.0.0 合约，需 ORI-62 组长转协议组/Node-Core 与 Control owner 确认后再执行相关验收：

1. 配对“已登录账户显式确认”的具体交互主体、码绑定目标 Node 的机制和审计字段；一次性秘密是否在传输/客户端 UI 避免剪贴板与截图。
2. HTTP 操作的幂等/重放防护范围、配对及 approval 的 request binding，以及事件去重的唯一键和保留窗口。
3. `approval.updated` 事件与批准凭据生命周期、撤权后的批准失效规则；拒绝和未配置 grant 的一致错误码。
4. 跨账户资源用 403 或 404 的统一策略；分页游标的账户绑定、过期及撤销并发语义。
5. 撤销对在线 Node 的安全检查点最大停止时延，以及 Node credential 轮换/丢失手机后用户 Session 的独立撤销路径。
6. iOS/Android 产品安全存储、备份与设备迁移的目标要求，以及真机最低 OS/测试矩阵。

执行顺序：**(1)** ORI-62 组长复核本设计及边界；**(2)** 将上述 6 项转协议组答复并固定决议/契约版本；**(3)** Node/Core 与 Control Plane owner 提供可测试环境和能力广告；**(4)** 手机组按 A–G 执行并附脱敏证据；**(5)** 单独进行至少 Android+iOS 双手机和真实 Node/Control 联调复核。当前步骤 (2)–(5) 尚未完成，本文不声称测试通过。

## 来源

- `protocol/contracts/multidevice-v1/README.md` 与同目录 schemas：1.0.0 / wire major 1，冻结于 2026-10-01。
- `docs/multidevice-contract-v1-verification.md`：2026-10-01 记录的 fixture 验证、生产只读检查及其覆盖边界。
- 项目状态来源：`/Users/jxcz/Agent Workspace/projects/orialis/state.md`（Multi-device protocol freeze — ORI-50，更新 2026-10-01）。
