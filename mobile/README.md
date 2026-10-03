# Orialis Flutter client

Orialis uses one Flutter application for Android and desktop-sized clients. The
domain repositories, Drift database, sync engine, realtime client and Lumina UI
package are shared; platform-specific behavior is limited to shell layout and
native capabilities such as file picking.

## Android

```bash
flutter pub get
flutter run
```

Production builds can inject the server URL:

```bash
flutter build apk --release \
  --dart-define=ORIALIS_SERVER_URL=https://orialis.jxcz.top
```

## macOS

The macOS Runner is tracked in this repository. Run the desktop entry directly:

```bash
flutter run -d macos -t lib/main_desktop.dart
```

The desktop entry uses a dedicated Lumina sidebar and shared domain repositories,
with non-chat task, project, calendar and settings views. See the desktop
documentation for the current capability and acceptance boundaries.

The shared design source of truth is `packages/lumina_ui/`; desktop code must
not reintroduce a second set of design tokens or components under
`mobile/lib/app/design/`.

## 手环连接开发

手机端“我的 → 手环连接”提供连接状态与消息诊断。Android已接入Xiaomi Wear SDK；实际节点授权与手机/手环互联仍待实机验收。见 [Wear README](lib/features/wear/README.md)。
