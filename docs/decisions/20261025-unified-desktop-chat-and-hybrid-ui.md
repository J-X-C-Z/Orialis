# Unified desktop chat and hybrid UI — 2026-10-25

Status: accepted for the isolated `codex/neumorphic-ui-test` experiment.

The user explicitly requested the new UI, chat/Intelligent UI upgrades and progress-summary behavior on macOS and Windows, with layouts designed for larger screens. This supersedes the older desktop non-chat scope documented in `desktop/local-release.md` and its historical acceptance matrix; earlier evidence remains historical.

All three clients use the existing Flutter application and local account/server-scoped databases. `main_desktop.dart` keeps desktop startup and platform integration boundaries. Desktop sync now includes chat, the realtime client advertises the implemented chat capabilities, and the platform handshake reports Windows correctly. Android-only capture, share and system-integration providers remain Android-only.

The original nine desktop navigation indexes remain stable; chat is appended as the tenth destination. Wide desktop layouts use a fixed navigation rail, a resizable-content working area and contextual visualizations from current local data. Chat receives its own conversations/detail layout and wider Intelligent UI. Medium and narrow windows simplify these regions instead of stretching the phone bottom navigation.

The common design layer supplies semantic multicolor light/dark palettes, recessed frosted wells, clear content and paint-only glass covers. Moving navigation layers share a single spring value. A unified new app icon and SVG state-symbol suite are platform resources; the content of user messages is not rewritten.

This is an experimental source/build decision. Record macOS/Windows/Android compilation, installation and runtime evidence separately; a successful build does not prove device acceptance. No protocol or database migration is introduced for the visual change.
