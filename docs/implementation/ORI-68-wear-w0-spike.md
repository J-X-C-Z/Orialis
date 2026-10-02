# ORI-68 Wear W0 Spike — 2026-10-02

## Status

W0 is **not passed**. The selected wearable is Xiaomi Smart Band 10 Pro. The phone is described as USB-connected, but its model, Android and Mi Fitness versions are unknown. The user reports the Mi Fitness third-party app entry is unavailable and says apps can be installed through AstroBox. At this check serial `83626d06` remains in ADB `authorizing` after `adb reconnect`; property reads still cannot proceed. The AstroBox install route is user-reported, not yet exercised for this Orialis RPK/device combination. No Orialis APK/RPK has been built, installed, signed, or exercised on a wearable in this work. Historical Fangcun evidence is not counted as Orialis acceptance.

This note records a bounded platform check and the evidence needed to resume W0. It does not select a device family or claim device support.

## Verified from current first-party documentation

| Fact | Source | Boundary |
| --- | --- | --- |
| Xiaomi publishes a Vela JS application framework for wearable applications, using `.ux` pages and JavaScript logic; AIoT-IDE supports macOS, Windows, and Ubuntu development. | [Xiaomi Vela JS APP overview](https://iot.mi.com/vela/quickapp/en/guide/) | This establishes a development framework, not support for a particular Band/Watch model, region, firmware, or Mi Fitness version. |
| Xiaomi's Vela FAQ states watch-to-phone communication checks the app signatures and requires matching certificates for the phone app and watch RPK. It also says the same release certificate must be retained across updates. | [Xiaomi Vela FAQ: communication signatures](https://iot.mi.com/vela/quickapp/en/guide/other/faq.html) | Orialis must use its own controlled signing identity and verify packaged APK/RPK fingerprints; no Orialis signing work has been performed yet. |
| Xiaomi's FAQ documents a Mi Fitness debug path for installing a local RPK, and says access to Mi Fitness for third-party Vela app development is currently arranged through its business group. | [Xiaomi Vela FAQ: RPK installation](https://iot.mi.com/vela/quickapp/en/guide/other/faq.html) | The documented menu path does not establish that the target account, region, phone, or firmware exposes the path. Official access/onboarding for this project is unknown. |
| Xiaomi recommends real-device debugging for simulator-to-watch communication. Its FAQ describes a startup `DISCONNECTED` observation and polling `getApkStatus()`, while its later best-practice page recommends the `diagnosis()` API instead of polling for communication status. | [Xiaomi Vela FAQ](https://iot.mi.com/vela/quickapp/en/guide/other/faq.html), [Vela startup best practices](https://iot.mi.com/vela/quickapp/en/guide/best-practice/start.html) | Follow the current `diagnosis()` recommendation and verify it against the SDK/version used. Simulator/static UI evidence cannot pass W0 interconnect acceptance. |
| AstroBox's official repository describes it as a Xiaomi Vela device resource ecosystem with Quick App installation. The user reports that AstroBox can install apps on this Smart Band 10 Pro. | [AstroBox official software repository](https://github.com/AstralSightStudios/AstroBox-Repo), [public source repository](https://github.com/AstralSightStudios/AstroBox-Public) | This supports AstroBox relevance only. The repo does not verify the exact install steps or successful installation/recognition of Orialis RPK on this band; ORI-69 should confirm supported package/signature and install flow with the user on-device. |
| The Vela interconnect feature requires `system.interconnect`; it says the paired Android app and Quick App package names/signatures must match. It sends to the paired mobile app and delivers receive/connection callbacks. | [Vela Device Communication Interconnect](https://iot.mi.com/vela/quickapp/en/features/network/interconnect.html) | This confirms the contract shape, not Smart Band 10 Pro support or installation access on our exact combination. |
| Vela `system.storage` offers callback based key/value persistence APIs (`get`, `set`, `delete`, `clear`). | [Vela Data Storage](https://iot.mi.com/vela/quickapp/en/features/data/storage.html) | Snapshot ACK must follow successful durable save; no Orialis persistence behavior has been implemented yet. |

## Open questions / required inputs

1. What exact Smart Band 10 Pro region/SKU and firmware are available?
2. What Android phone model/version and Mi Fitness version/account region will be used?
3. Which AstroBox app/version and exact install steps are available on the target phone/band, and does the SDK recognize the installed Orialis RPK? User reports AstroBox can install apps; this remains to be exercised.
4. Which Xiaomi Wearable SDK/AAR version and supported signing/build toolchain can be used? Obtain vendor materials through an authorized source; do not infer SDK access from public Vela JS documentation.
5. Who owns the non-exportable development/release signing keys? The current Orialis Android `applicationId` and Gradle `namespace` are both `top.jxcz.orialis` in `mobile/android/app/build.gradle.kts`; the new RPK must use this package after Android identity is confirmed. Do not reuse `app.fangcun`.
6. How does the existing Orialis Device model represent a companion inheriting phone trust without execution-node endpoints or permissions? Resolve against the current Device/Node contract before implementation.

The active Orialis Android `applicationId` and Gradle `namespace` are both `top.jxcz.orialis` in `mobile/android/app/build.gradle.kts`. The new RPK manifest must use this Orialis package after the paired phone app identity is confirmed; do not reuse `app.fangcun`.

## W0 compatibility and evidence matrix

Fill one row per exact combination. `Unverified` is the current status for every device-specific row until exercised and logged.

| Wearable model / region / firmware | Phone / Android | Mi Fitness | SDK/AAR | APK + RPK version / package | APK/RPK cert fingerprints | Install + app recognized | Ping/Pong both ways | UTF-8 snapshot + split / persisted ACK | Background/reconnect | Result / evidence link |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Xiaomi Smart Band 10 Pro (user-selected; region/firmware unknown) | USB-connected Android phone; model/version unknown; ADB reports `authorizing` despite user selecting “authorized”; Mi Fitness third-party app entry unavailable; user reports AstroBox install path (unverified) | Unknown | Unknown | Orialis app ID `top.jxcz.orialis`; RPK not built | Not checked | Unverified | Unverified | Unverified | Unverified | ORI-69 (Vela RPK) and ORI-70 (Android Wear Bridge) delegated; USB authorization mismatch remains open; user-reported AstroBox install route awaits hands-on validation |

Known phone connection observation: serial `83626d06` is visible to ADB over USB but remains `authorizing` after a reconnect; `adb get-state` and property reads return `device still authorizing`. The user selected “USB debugging authorized,” so the host/device authorization state is inconsistent and requires checking the on-phone RSA prompt or USB debugging authorization list. No model or Android properties were readable. The wearable itself is not reported as ADB-visible.

## Fangcun practices to adapt (read-only source review)

The user reports prior successful Smart Band 10 Pro work in Fangcun and asks to reuse its mature experience. The local Fangcun summary dated 2026-09-15 records one successful old RPK recognition and lays out an operational sequence. This is historical evidence, not Orialis acceptance. Its adapter and band interconnect implementation currently contain unresolved merge conflict markers, so neither source file is safe to copy wholesale or use as a build baseline.

| Fangcun material | Adapt for Orialis | Do not copy / current limitation |
| --- | --- | --- |
| `docs/PHONE-WRISTBAND-INTERCONNECT-SUMMARY.md` and `XiaomiWristbandAdapter.java` | Keep the same Android `applicationId` and RPK package, match APK/RPK certificates, discover the vendor node, check installed app and permissions, retain `lastError` plus separate service/node/install/permission state. Run SDK work and ACK waits asynchronously, not on the UI thread. | Never use Fangcun package, certificate, service endpoint, protocol tag, or credentials. The Android source has unresolved conflict markers and has not been recompiled in this review. |
| `apps/fangcun_band/src/utils/interconnect.js` and band README | Guard a missing interconnect service so the app can still show an unsupported state. Reassemble and validate a full transfer, persist it, then ACK with `transferId` and `revision`; keep prior valid snapshot on failure. | The interconnect source has unresolved conflict markers. Its 1200/256 and Android 2200-byte/3-retry/2500ms values are historical implementation values only; remeasure full serialized UTF-8 frames and negotiate actual SDK limits. |
| Fangcun receive-side pending action queue | Preserve stable request identifiers and query results when delivery is uncertain. | Do not port automatic offline replay for commands, approval, or other mutations. Orialis requires stale/permission/target revalidation and prohibits replay of sensitive operations. |
| Fangcun install notes | Treat copying an RPK to `Download` as transfer only; use the target Mi Fitness developer install path, reopen service, discover node, request permissions and launch the watch app; verify the app appears in the SDK. | The old sequence does not prove current Band 10 Pro firmware/region and Mi Fitness access. Avoid uninstalling an old app as a blanket first step because that may lose local state. |

Local Fangcun status at review: its working tree already has a modified `.DS_Store`; that source tree was not changed. The Orialis phone currently requires USB-debug authorization before its version and package identity can be captured. The band-side W0 RPK is assigned as ORI-69 to the wearable contributor. The Android Wear Bridge is outside the plugin team's `band/**` ownership and is formally handed off as ORI-70 to the mobile team lead for routing to its Android implementer.

## W0 exit checks (from ORI-68)

- Matching Orialis APK/RPK signatures, installed on the target combination and recognized by its SDK.
- Real-wearable Ping reaches the phone; Pong returns and is visibly rendered on the wearable, with correlated logs.
- Phone sends single-frame and fragmented snapshots containing Chinese and emoji; wearable validates, persists, ACKs, and reads the snapshot after app restart.
- Bluetooth disconnect/reconnect, Mi Fitness restart, phone backgrounding and lock-screen cases recover or report a specific limitation without false success.
- Wrong signature, absent RPK, absent node, denied permissions and lost ACK each produce distinguishable diagnostics; simulator UI still opens when interconnect service is absent.

No product UI, task commands, approvals, or mock transport should be presented as accepted until the platform gate above is cleared. Notification-only fallback, if tested, is a separately labeled read-only mode and does not pass W0 interaction.
