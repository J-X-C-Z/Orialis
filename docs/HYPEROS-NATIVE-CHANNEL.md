# 方寸 HyperOS 原生能力边界

网页壳和未来 Flutter 前端共用同一组原生语义，不让业务页面直接依赖具体 HyperOS 类名。真实 HyperOS 私有接口不可用时，能力层必须返回明确的 fallback 状态，不伪装成超级岛成功。

## 事件入口

Flutter 使用 `MethodChannel("app.fangcun/hyperos")`；现有 WebView 使用 `FangcunNative`。两者映射到相同事件：

| 语义 | 事件示例 | 原生动作 |
| --- | --- | --- |
| 专注开始/暂停/完成 | `focus.start` / `focus.pause` / `focus.complete` | 更新快照、尝试岛展示、触发对应触感 |
| 课程开始/结束 | `course.start` / `course.complete` | 更新快照、通知回退 |
| 截止提醒 | `ddl.remind` | 更新快照、通知和确认触感 |

Flutter 通道还提供 `getCapabilities`、`getSnapshot`、`haptic`、`clearEvent`、`refreshWidget`。返回值必须包含 `superIsland` 和说明字段；`superIsland: false` 时只能展示通知回退。

## 数据边界

Today Widget 只读取 `NativeSnapshotStore`，不访问 WebView 或网络。前端每次渲染后写入结构化 Today 快照，Flutter 迁移时沿用同一字段：`focus`、`nextEvent`、`deadlines`、`progress`。

原生模块不保存业务账号密码和 Agent 令牌。账号数据同步统一走 [Flutter—方寸服务器连接协议](FLUTTER-SERVER-CHANNEL.md)，原生能力通道只处理设备能力、事件和快照。

## 手环预备接口

<<<<<<< HEAD
手机侧使用统一协议 `fangcun.wristband.v1`。WebView 生产壳和 Flutter Android 宿主都调用同一份 Xiaomi AAR adapter；当系统没有 Mi Fitness/可用节点、权限未授予或 RPK 未安装时，仍返回明确的 `state`/`error`，不伪装已连接。生产 WebView 的 `FangcunNative` 与 Flutter 的 `MethodChannel("app.fangcun/hyperos")` 共用这些方法：
=======
手机侧预留统一协议 `fangcun.wristband.v1`，当前实现明确返回 `state: unsupported`，不申请蓝牙权限，也不伪装已连接。生产 WebView 的 `FangcunNative` 与 Flutter 的 `MethodChannel("app.fangcun/hyperos")` 共用这些方法：
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

| 方法 | 输入 | 返回重点 |
| --- | --- | --- |
| `getWristbandCapabilities` | 无 | `available`、`transport`、`features`、所需权限 |
| `getWristbandStatus` | 无 | 当前连接状态 |
| `connectWristband` | 可选设备筛选参数 | `ok`、`state`、`error` |
| `disconnectWristband` | 无 | `ok`、`state` |
| `syncWristband` | 未来测量/设备数据 | `ok`、`state`、`error` |

状态只允许 `disconnected`、`connecting`、`connected`、`unsupported`、`error`。未来接入具体厂商时替换 adapter，不让厂商 SDK 类型进入网页、Flutter 业务或 Rust 协议；异步设备事件另行使用 EventChannel，避免污染超级岛事件契约。
