## 当前界面版本 0.3.0-ui

手机非聊天页面对齐：今日、事件、日历、项目、我的。支持明确标记的本地互动演示，实际手机快照只读；自由中文编辑与账户/安全操作在手机完成。功能矩阵、日期/关系语义和验收边界见 [phone-parity-0.3.0.md](docs/phone-parity-0.3.0.md)，可选手机投影见 [phone-parity-contract.md](docs/phone-parity-contract.md)。保留当前W0缓存guard与持久ACK修复。

# Orialis Vela W0 + Glance UI

## 方寸 UI update — 0.2.1-ui / versionCode 3

The 2026-10-02 update follows the user's Fangcun reference: pure black, 20px home cards, 44px circular line glyphs, 82px menu/settings rows, 27px headers and 23px task titles. Home shows the current task, the phone-confirmed target and three independent connection states. A separate function menu provides Tasks / Commands / Devices / Settings; diagnostics is under Settings. List counts come from the current projection. Source badges explicitly distinguish empty/mock/stale/live. No fixed clock or placeholder live state is shown.

The shared application stores a bounded route-name trail while `router.replace` destroys previous page instances. Home left swipe opens the menu; subpages right swipe return to their entry layer; details right swipe closes the detail first. Only horizontal directions from Vela's swipe recognizer route. No haptics or remote operation was added. Compact mode reduces list notes, the demo toggle remains explicit/reset on restart, notification/vibration/stop/execution remain unavailable.

Build artifact: `dist/top.jxcz.orialis.debug.0.2.1-ui.rpk`. Design and handoff: [Fangcun design](docs/fangcun-design-20261002.md), [UI handoff](docs/fangcun-handoff-20261002.md). This update's GUI acceptance is pending the coordinating agent's AIoT IDE review; the screenshots below refer to 0.2.0-ui, not this version. Physical SDK and matching-signer acceptance remain open.

## Prior delivery — TASK-023 / 2026-10-02

Home / Tasks / Commands / Devices / Settings and a retained W0 diagnostics page are implemented in `src/pages/`. Official AIoT-toolkit **2.0.5** builds `dist/top.jxcz.orialis.debug.0.2.0-ui.rpk`. The real Xiaomi Vela simulator `10Pro` (336 × 480, generic **vela-pre-4.0**) launches the UX application, scrolls and navigates between pages; actual controller screenshots are under `docs/screenshots/`. This replaces the earlier same-day “no RPK / no simulator run” environment snapshot. It does **not** certify the physical Smart Band 10 Pro firmware or interconnect.

Default state is empty. Settings explicitly enables “演示 mock” for local preview; demo data is never written as a real phone snapshot or sent to the phone. All screens label their source. Cached data shows stale and supplied last-sync time (or unknown time); no remote operation is enabled. Tasks expand locally to compressed details. Commands display supplied waiting/failure/completion and a disabled confirmation view. Devices offer a local preview selection independently of the phone-confirmed target. Compact list is a persisted local preference; demo resets on app restart. Vibration and notification receive remain unavailable. See [design](docs/ui-design.md) and [adapter contract](docs/ui-adapter-contract.md).

One app-lifecycle transport owns interconnect and storage. Pages subscribe to `$app.$def.wearStore` and never connect directly to the SDK. Existing W0 UTF-8 limits, checksum, durable readback ACK, Ping correlation and timeout remain. `store.setScope()` supports future verified phone account/session/target changes and serializes durable guard + disk cache deletion after in-flight writes; no authenticated session-transition source is yet connected. All task stop, command execution, Agent actions, approvals and real route switching remain **待接入** with no dispatch or replay queue.

## Build and simulator

```sh
npm ci
npm test
npm run build
npm run start
```

Node >=18 is required by toolkit 2.0.5; this host used Node v26.8.1. Toolchain dependencies are project local, so `aiot` need not be globally on PATH. `npm run start` uses the official toolkit simulator workflow. On this host the existing simulator uses `~/.vela/vvd/10Pro.vvd/config.ini`, `~/.vela/sdk/system-images/vela-pre-4.0`, and the emulator controller at loopback port 8554. `scripts/simulator-ui.js` captures native emulator pixels and sends real touch/mouse gestures; it does not render a browser imitation. Restart the generic pre-4.0 VM before reloading the app after a build; killing/relaunching vapp in the same VM can leave LVGL initialized twice.

Use `node scripts/simulator-ui.js capture docs/screenshots/name.png`, `tap x y`, or `swipe x fromY toY` for reproducible UI evidence once the app is running. The initial list/automatic layout attempt was corrected using the documented scroll component and explicit non-shrinking children; current screenshots show readable Chinese instead of compressed text.

## Signing and device acceptance

The manifest package is `top.jxcz.orialis`, matching the Android application ID. The current UI simulator RPK uses the toolkit's development signer; it is **not** claimed to match the companion APK signer or to be usable for real-device pairing. A source debug certificate was exported from the existing Android debug keystore into an owner-protected directory **outside** the repository (`~/.orialis/wear-sign/debug`); no private key or symlink remains in source. No release key was exported. The final device package must be separately signed using the Android companion's verified debug/release identity and its actual embedded signer checked after packaging.

Before physical W0 acceptance, record APK/RPK package IDs, actual signer SHA-256 fingerprints, SDK/AAR source/version, handband region/firmware, Android/Mi Fitness versions and the chosen supported install route. Installing via AstroBox alone does not establish Android companion SDK recognition or certificate matching. The user reported AstroBox install support; no Orialis physical installation was performed in this delivery. Current phone-side SDK and native connectivity are owned by the mobile group, not this directory. Earlier ADB `authorizing` was a historical snapshot; current phone access is not accepted and must be read live by that group.

Physical acceptance remains open: matching-signer install, Android SDK node/app discovery/permissions, visible wrist Ping/Pong, Chinese/emoji snapshot readback after restart, actual session/target changes, and Bluetooth/Mi Fitness restart/phone lock-screen recovery. UI simulation and unit-level storage harnesses are not evidence for these real-device checks.

## W0 wire envelope (Orialis-owned)

Every message is a JSON object with `ns: "orialis.wear.v1"`, a `type`, and a `payload`. The app transport sends `{type:"ping", payload:{pingId,sentAt}}`; the phone companion must reply with `{type:"pong", payload:{pingId}}` using the same `pingId`. The wearable displays the returned ID only when it matches a pending Ping, with a 10-second timeout. It also responds to valid phone Ping with a matching Pong.

To send a snapshot, the companion serializes one JSON snapshot whose `transferId` and integer `revision` agree with the frame metadata. `snapshot.part` carries `{transferId,revision,index,count,checksum,chunk}`. `checksum` is the eight-hex-digit Adler-32 of the complete serialized UTF-8 JSON text. The watch reassembles chunks by index, verifies their metadata and checksum, parses the complete JSON and checks its transfer identity. Only after `system.storage.set` reports success and an exact `system.storage.get` readback matches does it send `{type:"snapshot.ack",payload:{transferId,revision}}`. A storage/readback error produces no ACK and leaves the last accepted in-memory projection intact. Lower revisions are rejected before writing. Cache invalidation is serialized after any in-flight write.

The protocol limits each serialized frame to 16 KiB UTF-8, each complete serialized snapshot to 16 KiB UTF-8, the transfer to 32 parts, concurrent incomplete transfers to four, and incomplete transfer retention to 60 seconds. Chunks end on Unicode scalar boundaries. UTF-8 size is calculated after JSON serialization so Chinese, emoji and escaping count toward the budget. These are conservative Orialis W0 limits, **not verified Xiaomi transport limits**. Adler-32 is a corruption check only, not authentication; paired APK/RPK signatures and the transport are the trust boundary.

The `storage.set` success callback is followed by `storage.get` and an exact string comparison before ACK. Xiaomi documents `storage.get`'s success value as the stored content, while `storage.set` documents a success callback without defining a returned value; the read-back is therefore the persistence check. A failed read or mismatch does not send ACK. The current repository task permits changes only under `band/**`. The phone-side SDK adapter and Android application integration remain outside this deliverable; the contract above is the handoff required for that integration. A local protocol-level test does not establish actual Vela or wearable interoperability.

## Verification record

See [TASK-023 verification](docs/verification-20261002.md) for the final artifact hash, exact checks, real simulator screenshots and remaining device gates.

## Sources

- [Xiaomi Vela interconnect](https://iot.mi.com/vela/quickapp/en/features/network/interconnect.html)
- [Xiaomi Vela storage](https://iot.mi.com/vela/quickapp/en/features/data/storage.html)
- [Xiaomi startup best practices (`diagnosis()`)](https://iot.mi.com/vela/quickapp/en/guide/best-practice/start.html)
- [Xiaomi manifest configuration](https://iot.mi.com/vela/quickapp/en/guide/framework/manifest.html)
- [Xiaomi AIoT-toolkit commands and versions](https://iot.mi.com/vela/quickapp/en/tools/toolkit/start.html)
- [Xiaomi AIoT-IDE simulator and project toolbar](https://iot.mi.com/vela/quickapp/en/tools/start/project.html)
- [Xiaomi IDE packaging and signing](https://iot.mi.com/vela/quickapp/en/guide/start/use-ide.html)
- [AstroBox Android/macOS installation and Android requirements](https://abox.run/docs/usage/install)
- [AstroBox supported devices and pairing](https://abox.run/docs/usage/connection)
- [AstroBox local RPK installation](https://abox.run/docs/usage/resource)

- [Xiaomi scroll layout and methods](https://iot.mi.com/vela/quickapp/zh/components/container/scroll.html)
- [Xiaomi shared app properties](https://iot.mi.com/vela/quickapp/en/guide/framework/script/global-data-method.html)
