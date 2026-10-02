# ORI-70 Android Wear Bridge — SDK gate (2026-10-02)

## Status

**Blocked before implementation; W0 is not passed.** Orialis has no Wear Bridge source or Xiaomi Wearable SDK/AAR in its Android module. No proprietary Fangcun artifact was copied. The plugged Android phone remains `authorizing` in ADB, so phone/Mi Fitness details and hardware checks are unavailable.

## SDK/API evidence

Xiaomi's official [Xiaomi Wear Third-Party App Capability Open Interface v1.4](https://vela-docs.cnbj1.mi-fds.com/vela-docs/files/%E5%B0%8F%E7%B1%B3%E7%A9%BF%E6%88%B4%E7%AC%AC%E4%B8%89%E6%96%B9APP%E8%83%BD%E5%8A%9B%E5%BC%80%E6%94%BE%E6%8E%A5%E5%8F%A3%E6%96%87%E6%A1%A3_1.4.pdf) documents the Java API identity and asynchronous task shape:

- `Wearable.getServiceApi(context)` with `ServiceApi.registerServiceConnectionListener` / `unregisterServiceConnectionListener`.
- `Wearable.getNodeApi(context)` with `NodeApi.getConnectedNodes()`, `isWearAppInstalled(nodeId)`, and `launchWearApp(nodeId, uri)`.
- `Wearable.getAuthApi(context)` with `AuthApi.checkPermissions(...)` and `requestPermission(...)`.
- `Wearable.getMessageApi(context)` with `sendMessage(...)`, `addListener(...)` and `removeListener(...)`.
- Calls return task objects and expose success/failure callbacks; adapter implementation must not block the UI thread.

This identifies the documented API version as **v1.4**, but the public document is not the SDK binary. It does not establish an authorized AAR artifact/version, Maven coordinate or package namespace, checksum, redistribution/license terms, supported target device/region, or whether Smart Band 10 Pro is supported. No `.aar` is present under `mobile/android`. The app identity is `namespace` and `applicationId` **`top.jxcz.orialis`** in `mobile/android/app/build.gradle.kts`; package match with the unavailable vendor library and watch RPK has therefore not been verified.

The official Vela documentation links to the interface PDF and an interconnect demo, while the existing ORI-68 spike notes that Xiaomi says third-party Vela development access is arranged through its business group. The exact access path for this project's Wear SDK is: request the Xiaomi Wear Third-Party App Capability SDK/AAR, version corresponding to interface v1.4, from Xiaomi's authorized wearable/partner developer channel; obtain its source/terms, artifact checksum, package/API identity and Smart Band 10 Pro compatibility statement; then provide the approved artifact or vendor repository access to the Orialis Android team. Do not fetch or vendor a reposted binary.

## Current evidence / remaining gate

| Evidence | Result |
| --- | --- |
| Android app identity | `top.jxcz.orialis` / `top.jxcz.orialis` |
| Android native bridge | Not implemented; `MainActivity` only has an unrelated haptics channel |
| Authorized SDK/AAR | Not confirmed or available in repository; v1.4 is documentation version only |
| API package identity / dependency provenance | Unknown pending authorized AAR/source |
| Service connection, node count, RPK installed, permissions, last error | Not instrumented; no SDK/runtime observations |
| Phone / Android / Mi Fitness | Unknown; ADB serial `83626d06` is `authorizing` |
| Wearable / region / firmware | Selected target is Smart Band 10 Pro; region and firmware unknown |
| Ping/Pong, transport callbacks vs app response | Not implemented or exercised |
| Android build | Attempted `./gradlew :app:assembleDebug` in `mobile/android`; stopped before Gradle because macOS reports `Unable to locate a Java Runtime`. No build result for this checkout. This cannot substitute for SDK-linked build or device acceptance |
| W0 | Not passed |

Resume when the authorized AAR and its license/provenance are supplied and USB debugging is authorized. Then implement the native adapter in mobile-owned Android files, keep SDK tasks and ACK waits asynchronous, build against the actual AAR, and complete real-device evidence. Preserve the separate `serviceConnection`, `nodeCount`, `wearAppInstalled`, `permissionsGranted` and `lastError` diagnostics; keep transport delivery callbacks distinct from the Vela app-level Pong response.
