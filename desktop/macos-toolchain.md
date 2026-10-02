# macOS toolchain handoff — 2026-10-01

Source: JXC-46 local verification in the authoritative Orialis repository.

## Verified

- macOS 27.0.1 (26A434); host `uname -m`: arm64.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Xcode 27.0 (27A266a); `xcodebuild -checkFirstLaunchStatus` exits 0.
- macOS SDK: Xcode's `MacOSX27.0.sdk`.
- CocoaPods 1.17.0.
- Flutter 3.47.4, Dart 3.13.3; writable cloned SDK and pub cache start successfully.
- A minimal C program compiled with `xcrun --sdk macosx clang -arch arm64` and executed successfully in run scratch.
- `flutter devices` identifies the macOS desktop target.

## Reproduce in a Paperclip run

Run from the repository root with Bash. The source command retains environment
variables in the current shell; invoking the script as a child process does not.

```bash
source desktop/prepare-macos-toolchain.sh
flutter doctor -v
flutter devices
```

The script uses the existing run-owned `PAPERCLIP_SCRATCH_DIR` (or
`PAPERCLIP_RUN_SCRATCH_DIR`), macOS copy-on-write copies of the system Flutter SDK
and pub cache, and scratch-local configuration. It leaves HOME, CODEX_HOME and
global xcode-select unchanged. Scratch is removed at run end; repeat preparation
in each new run. Optional source overrides are ORIALIS_FLUTTER_SOURCE and
ORIALIS_PUB_CACHE_SOURCE. Do not run concurrent preparation against the same
scratch directory.

After the product owner creates and verifies `mobile/macos` and its desktop entry,
continue in the same prepared shell:

```bash
cd mobile
flutter pub get
flutter build macos --release --target lib/<verified-desktop-entry>.dart
```

The entry above is a placeholder, not an existing file. No product release or
launch was tested by this environment task. The product owner must supply the
actual entry, plugin resolution, release output, and installation/launch evidence.

## Diagnostic limits

Flutter doctor reports additional Xcode components because its simctl booted-device
probe fails. The observed failure includes denied writes to user CoreSimulator
logs and an unavailable CoreSimulatorService in this restricted run. First-launch
status and macOS native compilation pass; this probe does not establish a missing
macOS compiler. Simulator runtimes have not been verified.

Flutter doctor/devices report darwin-x64, but `uname -m` and `file` on the copied
Dart executable report arm64. Treat the Flutter label as a diagnostic discrepancy;
inspect the final application binary architecture during product acceptance.
Chrome is absent and Web doctor fails; the target for this delivery is macOS.

At verification time, no product `mobile/macos` directory exists. Existing modified
product files were preserved. Product work remains with the mobile path owner in
JXC-37; no task was reassigned across teams or projects.
