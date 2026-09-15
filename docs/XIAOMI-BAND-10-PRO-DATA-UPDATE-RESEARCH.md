# 小米手环 10 Pro 数据更新路线研究

## 结论

社区实测已经验证另一条可行路径：小米手环 10 Pro 仍由 Mi Fitness 负责绑定和蓝牙连接，但可以通过表盘自定义工具/AstroBox 安装 Vela 快应用，再由手机 companion App 通过小米穿戴通信库把自定义 JSON 传给手环端。BandBBS 的弦电子书已用这条链路同步书籍、封面、阅读进度和阅读时长。官方 FAQ 与社区实践存在冲突，本项目以社区实机方案为实现依据，并保留通知/系统日历作为降级路径。

方寸可用的实际更新面有三条：

1. **Vela 快应用 + companion App**：主路径，传输 `fangcun.link.v1` 快照，支持手环自定义页面展示。
2. **App 通知**：连接失败或未安装快应用时的降级路径。
3. **系统事件**：把课程/日程写入手机系统日历，再由 Mi Fitness 同步到手环 Events。

## 证据

- [Xiaomi Smart Band 10 Pro 官方 FAQ](https://www.mi.com/global/support/faq/details/KA-703579/)：支持第三方 App 通知；通知最多保存 20 条；手环只能查看不能回复；Events 可同步手机系统事件最近 7 天且最多 20 条；Tasks 最多同步 20 条；第三方 App 安装项明确为不支持。
- [Xiaomi Vela Interconnect 官方文档](https://iot.mi.com/vela/quickapp/en/features/network/interconnect.html)：对支持 Vela 第三方应用的设备，提供 `system.interconnect`、`connect.send` 和 `connect.onmessage`，并要求手机 App 与手环 App 包名、签名一致。
- [小米穿戴第三方 App 能力开放接口 v1.4](https://vela-docs.cnbj1.mi-fds.com/vela-docs/files/%E5%B0%8F%E7%B1%B3%E7%A9%BF%E6%88%B4%E7%AC%AC%E4%B8%89%E6%96%B9APP%E8%83%BD%E5%8A%9B%E5%BC%80%E6%94%BE%E6%8E%A5%E5%8F%A3%E6%96%87%E6%A1%A3_1.4.pdf)：对支持的穿戴设备提供 `MessageApi`（应用间数据）和 `NotifyApi`（系统通知），并要求申请设备管理/通知权限。

## 能力矩阵

| 目标 | 小米手环 10 Pro | 方寸实现方式 | 适合内容 |
| --- | --- | --- | --- |
| 手环通知列表 | 支持 | Android Notification → Mi Fitness | 任务提醒、课程开始、同步状态 |
| 手环 Events 应用 | 支持系统事件同步 | 写入 Android Calendar | 课程、考试、日程 |
| 手环 Tasks 应用 | 支持有限任务同步 | Xiaomi/REDMI 手机系统任务/Notes | 待办任务 |
| 方寸自定义手环 App | 社区已验证 Vela 快应用安装 | `.rpk` + 表盘自定义工具/AstroBox | 主路径 |
| 手机直接写自定义 JSON 页面 | 社区项目使用穿戴通信库 + `system.interconnect` | `fangcun.link.v1` 分片传输 | 主路径 |
| 手环端回复并回传方寸 | 可通过 ACK/消息回传 | 当前只回传同步 ACK | 已实现基础链路 |

## 推荐实现

### 第一层：Vela 快应用数据同步

Android 端使用社区项目验证过的 `xms-wearable-lib_1.4_release.aar`，完成节点发现、设备授权、打开手环 App、消息监听和发送。手环端使用 `system.interconnect`，接收 `fangcun.link.v1` 的单包或分片快照，写入本地文件并回复 `fangcun.link.ack`。Android 端按 ACK 判断传输成功，并负责握手、重试和断线恢复。

### 第二层：通知，立即可用

保留当前 Android 通知实现，把 `fangcun.link.v1` 的业务对象转换为简短通知：

```json
{
  "type": "notification",
  "title": "方寸 · 课程提醒",
  "body": "大学物理将在 10 分钟后开始 · 东校 A301",
  "deepLink": "fangcun://course/course-123"
}
```

手机上需要开启方寸通知权限；Mi Fitness 中需要进入“设备 → 通知与通话 → App 通知”并选择方寸。通知正文不要依赖 JSON，因为手环只把它当文本展示。

### 第三层：系统事件，适合“今天安排”

方寸已有系统日历同步入口。应把课程、考试和重要日程写入 Android Calendar，并提供一个“同步到小米手环 Events”的明确操作。写入后让用户在 Mi Fitness 中开启“Sync events”。需要遵守最近 7 天、最多 20 条和 MIUI/HyperOS/iOS 平台限制。

### 第三层：系统任务，谨慎支持

官方路径要求在 Xiaomi/REDMI 手机上通过系统 Notes 创建待办，再在 Mi Fitness 中执行 Sync tasks。普通 Android 上没有统一的公开任务提供者，因此方寸不能承诺跨品牌自动写入系统 Tasks。第一版可以继续使用通知；若需要在手环 Tasks 中看到任务，应针对 Xiaomi/REDMI 系统做单独适配和实机验证。

## 不应采用的路线

- 不让方寸直接扫描或抢占手环 BLE 连接，否则会与 Mi Fitness 的绑定链路冲突。
- 不把 Vela `system.interconnect` 直接接入当前手环工程；该接口适用于能安装 Vela 第三方 App 的设备，而官方 FAQ 说明 Smart Band 10 Pro 不支持第三方 App。
- 不逆向 Mi Fitness 私有协议作为首选方案；即使能发送，也会遇到绑定、签名、固件版本和更新兼容性问题。

## 最终验收标准

1. Mi Fitness 仍是唯一绑定 App。
2. 方寸发送测试通知后，手环通知列表出现方寸消息。
3. 方寸同步课程后，支持的系统事件能在手环 Events 中出现。
4. 任务提醒至少能通过通知稳定送达；系统 Tasks 仅在 Xiaomi/REDMI 实机上作为可选增强。
5. 方寸界面明确显示每条数据走的是“通知”“系统事件”还是“系统任务”，不显示虚假的“方寸手环 App 已连接”。
