# ADR-004：桌面 v1 获批决策记录

- 状态：Accepted（技术与范围）；实现与产品验收尚未完成
- 日期：2026-10-01
- Owner Role：desktop-architect
- 来源：[JXC-34 计划](/JXC/issues/JXC-34#document-plan)，revision 1 / `8a2f6743-867a-46f8-8d74-db375f22d205`
- 用户接受记录：interaction `11107de7-f575-49fd-88ad-609ddbe28b70`，accepted，version 1

## 决策

采用 Flutter Desktop，macOS 首发，在现有 `mobile/` Flutter 应用增加 macOS 产品宿主和桌面入口/壳层。复用现有 Repository、Drift 数据库、HTTP/Session 与领域同步，保留目录名，不建立第二份业务实现。Windows/Linux 为后续扩展，不承诺本轮交付。Lumina 光构、ADR-006、共享 token 与手机端可操作行为是视觉与能力基线。

对齐今日、任务/事件、单层子任务、项目/里程碑、日历/日程、账户/设置和本地优先同步。完整行为矩阵与故障验收按上述获批 revision 执行。提醒和重复设置需正确编辑、保存和同步；不以字段存在宣称系统通知或循环执行器已完成。

排除聊天页面、会话/消息、引用、Hermes 模型/命令、聊天附件/拍照和 Agent 交互卡片。其他客户端创建的合法任务/日程继续进入领域同步。新增通知调度、托盘、自动更新、多窗口和导入导出不在范围内。

## 边界和约束

- `mobile/**` 由 orialis-mobile-coder 实施，包括宿主、桌面业务页面、平台适配及同步隔离。desktop-coder 不获准跨路径修改。
- `packages/lumina_ui/**` 的桌面焦点、回调和视觉适配交 desktop-coder；仅包含通用组件，不放业务、数据或网络。
- `desktop/**` 保存架构及验收索引；本记录不改变 canonical ADR 的存放策略。
- 桌面启动和同步必须显式隔离聊天依赖、推拉及附件，不能仅隐藏路由。保留领域 cursor、change_hint、heartbeat、断线 HTTP 恢复及兼容数据库迁移。
- Task 与 Schedule 独立，Today 为聚合；不另造协议。身份和服务器切换、401/409、tombstone、snapshot、离线重启和休眠唤醒需验证。
- 不自动 stash、reset、切分支或合并。先由各路径 owner 记录当前未提交成果和安全实施基线，再作可追溯的小步修改；批准技术方案不等于批准 Git 分支处理。

## 证据与旧文档修正

本轮只读确认：权威仓库 `Lumina-UI` / HEAD `bdc0380`，多路径存在未提交成果；`mobile/` 未发现产品 macOS Runner。组件 example 的 macOS Runner 不构成产品交付。旧外层 ADR 关于上游产品宿主已经完成的断言与已确认事实不一致，其聊天/附件任务也不适用于本轮。

外层 `projects/orialis/decisions/ADR-004-desktop-client-stack.md`、state、roadmap 和 memory 位于当前沙箱可写范围之外；本轮没有覆盖它们。通过独立维护任务交由有对应路径权限的 owner 同步，并在 Paperclip 保存本记录供查阅。不得据此宣称外层文档已更新。

## 交付标准

macOS 可安装 release、逐项能力矩阵、浅/深色及窄/宽窗截图、手机↔桌面真实往返和故障记录、无聊天端点调用证据、相关手机回归，以及独立 reviewer 结论。未取得真实跨设备或安装验证时，不标记产品已完成。

本记录不包含产品代码变更或构建通过结论。
