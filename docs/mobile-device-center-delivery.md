# ORI-62 手机端 Device Center 交付记录

日期：2026-10-01
契约边界：`protocol/contracts/multidevice-v1` 1.0.0；服务器 Node/Control API 尚未部署，`/api/v1/capabilities` 尚未广告 `multidevice.v1`。

## 已实现

- 手机「我的」页面增加设备中心入口及 `/devices` 路由。
- Device Center 展示设备名称、平台、在线/离线状态、当前/默认标识和 Capability 的可用/授权状态；支持切换当前设备、重命名、设为默认和本地移除。
- `DeviceDataSource` 定义可替换适配边界。当前 provider 指向明确标注的 `FixtureDeviceDataSource`，所有演示设备 ID 均以 `fixture-` 开头；添加设备会明确提示 API 未就绪，不伪造配对。
- `orialis.currentDeviceId` 持久化当前选择。提供 `DeviceScopedCache`，缓存键显式采用设备 ID，切换 Node 时不得复用另一 Node 的条目。

## 验证与日志

从仓库 `mobile/` 目录运行：

```sh
flutter test test/device_center_test.dart
dart analyze lib/features/devices lib/app/router/app_router.dart lib/pages/profile/profile_page.dart test/device_center_test.dart
```

已运行的测试日志：

```text
00:00 +0: loading test/device_center_test.dart
00:00 +0: fixture identifies itself and supports rename/default/remove
00:00 +1: device scoped cache keeps values separate after switching
00:00 +2: All tests passed!
```

`dart analyze` 定向检查结果：`No issues found!`

## 覆盖边界

这些测试只验证本地 fixture CRUD 和按 `deviceId` 键隔离的内存缓存，不验证真实 pairing、真实 Session/Node 授权、服务端撤销、双手机同步、真实 Capability 数据或端到端视图数据切换。当前 Orialis 服务不存在 Node/Control 路由，不能把 Fixture 当成平台验收证据。

## 待接入契约与回接

1. 接入前发现 `/api/v1/capabilities` 中的 `multidevice.v1`，再以合约规定的 Session 认证访问 `/api/v1/nodes`、`/nodes/{deviceId}` 和 `/nodes/{deviceId}/capabilities`。
2. pairing 的显式确认、一次性凭据、授权与撤销必须服从冻结合约；服务端缺失时保持失败关闭。任何字段/语义变更回协议组协调，不在手机客户端本包自行扩展。
3. 用真实 Android/iOS 设备、真实账户和已部署 Node/Control 实现完成安全威胁模型中的 A–G 验收，并分别记录服务器版本、设备日志和证据。
4. 安全测试设计与真机环境清单见 `docs/mobile-device-security-test-plan.md`；并行子任务 [ORI-64](/ORI/issues/ORI-64) 已由开发部长复核通过。设计稿不是安全测试执行结果。

## 回接清单

- **手机端实现接入：** 保留 `DeviceDataSource` 为替换边界；待后端能力广告显式包含 `multidevice.v1` 后，新增契约适配器调用已冻结的 Node/Control 路由。检查 HTTP 错误为能力缺失时保持关闭，不回退到 Hermes `agent-devices`。
- **状态与缓存：** 当前设备偏好键为 `orialis.currentDeviceId`；Device Center 本地缓存 helper 以 device ID 分区。接真实数据层时，各 domain repository、查询键与离线持久化都需带 account ID + device ID/Node ID；切换账户或设备时清空旧 scope 或重新装载，验证不会闪现前一设备数据。
- **CRUD 语义：** fixture 中 rename/default/remove 只改内存；接入适配器后映射到冻结契约的设备显示名、当前选择与撤销语义。远程撤销成功前不得把“本地移除”显示成服务端已撤销。
- **安全与真机：** 按 `docs/mobile-device-security-test-plan.md` 先完成协议待决项确认和 Node/Core、Control Plane 实现/能力广告部署，再执行 A–G。记录 Android+iOS 真机、版本、脱敏日志与清理证据；fixture/序列化校验不得作为配对、认证、撤销或双手机验收。

## 协议与环境依赖

当前 UI/DataSource 以 `protocol/contracts/multidevice-v1` 1.0.0 为目标边界；不扩展字段。安全稿列出的 HTTP 重放/幂等与 request binding、跨账户 403/404 策略、审批凭据失效、撤销安全检查点时延、移动端凭据存储/备份矩阵，须由协议组及 Node/Core、Control Plane owner 确认。后端部署并广告能力前，手机端仅可复现 fixture 测试及真实环境的只读能力发现/负向检查。
