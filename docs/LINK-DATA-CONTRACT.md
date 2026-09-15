# 方寸手机互联数据标准 v1

## 目标

`fangcun.link.v1` 是手机端、手环端和未来其他设备之间的业务数据格式。业务格式不绑定具体厂商 SDK；当前 Xiaomi Vela 传输层使用手机 companion App + `system.interconnect`，服务端仍只读，手环端也只读展示。

## 快照信封

每次读取返回一个 JSON 对象：

```json
{
  "schema": "fangcun.link.v1",
  "version": 1,
  "type": "snapshot",
  "messageId": "snapshot-…",
  "timestamp": "2026-09-15T10:00:00.000Z",
  "source": "server",
  "dataState": "live",
  "device": { "id": "fangcun-phone", "kind": "phone", "name": "方寸手机端", "platform": "web" },
  "account": { "id": "1", "displayName": "…", "username": "…" },
  "sync": { "revision": 4, "cursor": "4", "updatedAt": "…", "lastSyncAt": "…", "mode": "pull-only", "canWrite": false },
  "payload": { "deviceStatus": {}, "schedule": {}, "tasks": {}, "syncState": {} }
}
```

`dataState` 只能是 `mock`、`live`、`stale` 或 `empty`。因此演示数据与真实读取结果不会混淆。

## 首批业务载荷

- `deviceStatus`：设备状态、剩余电量、充电状态和固件信息。当前设备未连接时，这些字段为 `null`。
- `schedule`：`date` 为 `YYYY-MM-DD`，`items` 为课程/安排列表；每项至少包含 `id`、`kind`、`title`、`location`、`day`、`startSection`、`endSection`。
- `tasks`：`date`、`pendingCount` 和最多 20 项未完成事项；每项包含稳定 `id`、标题、DDL、重要/紧急标记和关联对象 ID。
<<<<<<< HEAD
- `projects`：`count`、`pendingActionCount` 和项目摘要；每项包含项目目标/期限/状态、按里程碑与关联任务计算的 `progress`、最多 4 个里程碑摘要，以及最多 5 个未完成关联行动。没有项目时仍返回 `{count:0,pendingActionCount:0,items:[]}`。
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
- `syncState`：当前为 `mode: "pull-only"`、`canWrite: false`、`transport: "not-connected"`。

## 只读接口

- `GET /api/v1/link/health`：不返回用户数据，返回协议版本、传输层状态和是否已登录。
- `GET /api/v1/link/snapshot`：需要方寸会话，返回当前用户的标准化快照。

服务端不提供写入接口；手机到手环的本地传输只写入手环快应用自己的快照文件，不修改方寸云端数据。手机不直接扫描或抢占 BLE，仍依赖 Mi Fitness 的设备连接和授权状态。

## 小米手环 10 Pro 传输路径

小米手环继续由 Mi Fitness 负责绑定和蓝牙连接。方寸 Android App 不直接抢占 BLE，而是使用社区已验证的小米穿戴通信库发现节点、申请设备权限并发送消息；手环端方寸 Vela 快应用通过 `system.interconnect` 接收消息。单包消息直接发送，较大的快照拆成 `fangcun.link.v1` 分片；手环完整落盘后回复 `fangcun.link.ack`，手机收到 ACK 才报告同步成功。

<<<<<<< HEAD
手机登录并完成一次服务器同步后，会重新读取 `/api/v1/link/snapshot` 的最新标准化快照；若存在 Android 穿戴桥，则按 revision 去重并自动发送给手环。手环收到并确认 ACK 后，首页、任务页、日程页和长期项目页会刷新；未安装快应用或连接失败时，手机保留待重试状态，通知仍可作为降级路径。方寸 Android App 的“手机互联”面板也保留“同步到手环”和“发送测试通知”手动入口。
=======
方寸 Android App 的“手机互联”面板提供“同步到手环”和“发送测试通知”。消息内容均来自本协议；未安装快应用或连接失败时，通知仍可作为降级路径。
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

## 冲突与演进

记录使用稳定 `id`、`updatedAt`；服务端 revision 作为同步游标。当前手机端是唯一写入端，手环未来只读。新增字段必须保持向后兼容；破坏性变化升级 `version`，不在 `v1` 中重新解释既有字段。
