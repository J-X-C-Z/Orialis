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

The macOS Runner is generated from the current Flutter stable template so the
repository does not carry a second copy of generated platform boilerplate:

```bash
bash ../scripts/bootstrap-macos.sh
flutter run -d macos
```

At desktop widths Orialis switches to the Lumina sidebar shell. Chat and
Projects use list-detail layouts, desktop file picking is native, and
`⌘1`–`⌘5` switch primary sections while `⌘,` opens settings.

The shared design source of truth is `packages/lumina_ui/`; desktop code must
not reintroduce a second set of design tokens or components under
`mobile/lib/app/design/`.
