# orialis_mobile

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.


## macOS

The macOS client reuses the same Flutter application, repositories, local
database, sync engine, realtime client, and Lumina components as mobile.

The native Runner is intentionally generated from the current Flutter stable
template instead of being hand-maintained:

```bash
bash ../scripts/bootstrap-macos.sh
flutter run -d macos
```

At desktop widths Orialis switches to a Lumina `Solid Sidebar + Glass
Interaction` shell. Chat also becomes a two-pane conversation/detail layout.
Common navigation shortcuts are `⌘1`–`⌘5`; `⌘,` opens settings.
