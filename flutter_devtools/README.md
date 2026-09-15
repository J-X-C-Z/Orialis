<<<<<<< HEAD
# 方寸 Flutter 最小客户端

这是方寸 Phone 同步的最小 Flutter 客户端。它直接使用 `rust-server` 的 `/api/v1` 接口，支持登录、读取当前账号数据、展示任务、创建任务、完成/恢复任务和按 revision 写回服务器。

当前范围刻意保持很小：登录态暂存在进程内，数据以 Rust Server 返回的完整文档为基础，尚未加入本地 SQLite、Outbox 和 WebSocket。它用于先验证 Flutter → Rust 的真实数据闭环，再逐步替换为完整 Local-first 客户端。
=======
# 方寸 Flutter 开发者模式

这是路线图 Phase 9 的预备工程，不替换当前生产 Android 壳。它提供一套可独立运行的 Flutter UI，用来预览和主动触发超级岛、Focus、课程、DDL 与语义触感事件。
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

## 运行

```bash
export PATH="$PWD/../.tooling/flutter/bin:$PATH"
flutter pub get
flutter run
```

<<<<<<< HEAD
默认 Server 地址：

- Android 模拟器：`http://10.0.2.2:4173`
- 桌面运行：`http://127.0.0.1:4173`

真机请填写 Rust Server 的局域网地址或 HTTPS 地址。启动 Rust Server：

```bash
FANGCUN_ROOT="$PWD" cargo run --manifest-path rust-server/Cargo.toml
```

首次使用时先在网页端或通过 `/api/v1/auth/setup` 创建管理员账号。

Flutter 与 Rust 的数据请求走 `flutter_devtools/lib/server_client.dart`。登录后读取：

```text
GET /api/v1/data
```

创建、完成或恢复任务时使用：

```text
PUT /api/v1/data
{ data, baseRevision }
```

服务端 revision 发生冲突时，界面会提示冲突并重新读取服务器数据，避免静默覆盖远端内容。

原有 Android 原生能力仍通过以下 MethodChannel 保留，供后续接入手环和通知：
=======
右下角悬浮窗中的事件会通过以下 MethodChannel 发给 Android 原生适配层：
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

```text
app.fangcun/hyperos
```

支持的方法：

```text
triggerEvent({ event, payload })
getCapabilities()
getSnapshot()
haptic({ semantic })
clearEvent()
setDeveloperMode({ enabled })
refreshWidget()
```

当前 Flutter 工程自带 Android 宿主实现；超级岛没有公开、可验证的通用 Android API，因此真实设备上使用高优先级通知作为回退，同时保留 `IslandManager` 接口供 HyperOS 专用适配接入。主 APK 的 Debug 包则使用同一事件模型的原生开发者悬浮窗。
