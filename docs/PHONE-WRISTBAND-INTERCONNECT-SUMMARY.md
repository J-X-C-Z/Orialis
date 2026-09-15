# 手机—手环互联方案（已验证基线）

更新时间：2026-09-15

## 结论

当前可行路径是：

```text
服务器 /api/v1/link/snapshot
        ↓ HTTPS + Session 鉴权
手机方寸 App
        ↓ Android Native Bridge
Xiaomi Wearable AAR / Mi Fitness 服务
        ↓ system.interconnect
Vela 手环端方寸 RPK
```

手环不直接访问服务器。服务器只生成只读标准化快照，手机负责拉取并转发，手环负责接收、落盘和展示。

## 数据协议

- 协议标识：`fangcun.link.v1`
- 消息类型：`snapshot`、`chunk`、`handshake`、`heartbeat`、`ack`
- 服务端接口：`GET /api/v1/link/snapshot`
- 快照内容：今日课程/日程、待完成任务、长期项目、项目进度、里程碑、最近完成事项、下一步行动和待执行行动。
- 服务端快照为 `pull-only`，`canWrite: false`。
- 手机按 `sync.revision` 去重，只有新版本才发送到手环。

## 手机侧

### WebView 方寸 App

完成登录或云端同步后，手机重新读取服务端 `/api/v1/link/snapshot`，校验 `fangcun.link.v1` 契约，然后调用：

```text
FangcunNative.connectWristband()
FangcunNative.syncWristband(snapshot)
```

同步成功以手环返回 `fangcun.link.ack` 为准。未登录、无原生桥、未连接手环或发送失败时，不伪装成功，保留待重试状态。

### Android 原生适配器

`XiaomiWristbandAdapter` 使用 Xiaomi Wearable AAR：

1. 发现已连接的 wearable node。
2. 检查手环 RPK 是否已安装。
3. 检查/申请 `DEVICE_MANAGER`、`NOTIFY` 权限。
4. 注册消息和连接监听。
5. 发送握手、快照分片并等待 ACK。

重要实现约束：WebView 的 JavascriptInterface 在 Android 主线程同步调用。`sendMessage()` 的 SDK Task 不能在该线程阻塞等待；发送完成应由协议层 ACK 判断。此前对 SDK Task 使用主线程等待会导致消息被误判为发送失败，现已修复。

## 手环 RPK 要求

手环端必须使用 Vela RPK，manifest 至少包含：

- `package: app.fangcun`
- `deviceTypeList: ["watch"]`
- `features` 包含 `system.interconnect`、`system.storage`

最关键的兼容规则：

> 手机 Android App 与手环 RPK 必须使用相同包名和相同签名证书。

本机已验证：

- 2026-09-15 13:08 的 `/sdcard/Download/app.fangcun.current.debug.rpk` 可以被识别。
- 该包使用 Android Debug 证书（SHA-256：`48:3C:75:AA:7B:B7:59:1F:60:8C:C7:34:46:E5:87:25:69:B2:A0:C9:FF:47:CB:0C:59:B8:D7:B1:76:65:48:ED`）。
- 后续用 Vela 工具默认 `localhost` 证书生成的 RPK 无法被手机识别，尽管包名和 `system.interconnect` 声明相同。
- 因此调试 RPK 必须使用本机 `~/.android/debug.keystore` 导出的证书/私钥，并放在构建时的 `sign/debug/certificate.pem`、`sign/debug/private.pem`；私钥不能提交到仓库。

RPK 放进手机 `Download` 目录只完成文件传输，不等于安装到手环。还必须通过 Mi Fitness/Vela 开发环境安装到目标手环，并让 Mi Fitness 保持后台运行。

## 已验证的操作顺序

1. 用 Android Debug 证书构建 RPK。
2. 将 RPK 传到手机 `Download`。
3. 在 Mi Fitness/Vela 开发入口卸载旧版并安装 RPK 到手环。
4. 重启或重新打开 Mi Fitness。
5. 打开方寸 Android App，进入开发者模式。
6. 执行“检查连接并请求权限”。
7. 执行“打开手环端方寸”。
8. 登录并同步服务器数据，或手动执行“同步到手环”。

## 排障信息

开发者状态应重点查看：`nodeCount`、`wearAppInstalled`、`permissionsGranted`、`serviceConnection`、`lastError` 和 `lastRevision`。

已知现象：手机蓝牙显示已绑定 `Xiaomi Smart Band 10 Pro`，不代表 Xiaomi Wearable SDK 已找到可用 node；蓝牙开启但 RPK 未安装、签名不一致或 Mi Fitness 服务未正常工作时，SDK 仍可能返回无 node 或无法识别。

## 已知限制

Smart Band 10 Pro 的第三方 Vela 应用支持依赖具体固件、Mi Fitness 版本和社区验证路径；官方支持范围可能不包含所有第三方应用。当前方案以“本机旧版 RPK 已成功识别”为事实基线，不把单纯蓝牙配对当作互联成功。

## 相关实现

- 服务端快照：[rust-server/src/main.rs](../rust-server/src/main.rs)
- 手机契约与自动同步：[link-contract.js](../link-contract.js)、[app.js](../app.js)
- Android 适配器：[XiaomiWristbandAdapter.java](../android/app/src/main/java/app/fangcun/XiaomiWristbandAdapter.java)
- 手环互联：[apps/fangcun_band/src/utils/interconnect.js](../apps/fangcun_band/src/utils/interconnect.js)
- 数据契约：[LINK-DATA-CONTRACT.md](LINK-DATA-CONTRACT.md)
