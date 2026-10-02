# TASK-023 handband UI verification — 2026-10-02

Source: user / 2026-10-02; `manager/wear-continuation-20261002.json` band work packet; own implementation and official-toolchain run.

## Delivered

Five business UI pages and retained W0 diagnostics; real page navigation, vertical small-screen scrolling, Chinese empty states, local task detail, supplied command status/detail and disabled confirmation, local device selection preview, local compact preference and explicit demo toggle. The default starts empty. No remote business action, approval or route change is sent. Read-only snapshot/store/protocol integration and persistent cache invalidation are implemented; authenticated phone session hooks remain to be integrated by the owning groups.

## Final artifact

- `dist/top.jxcz.orialis.debug.0.2.0-ui.rpk`
- Size: **45423 bytes**.
- SHA-256: `afb1f83126e2d167dffc47284351842eead0202232a554e702d29b33ad4a5098`.
- Official aiot-toolkit 2.0.5 build: passed, six registered routes, no unsupported component/attribute warnings in the final build.
- Manifest package: `top.jxcz.orialis`, versionName `0.2.0-ui`, versionCode `2`.
- Signer: current toolkit development identity, **UI simulation only**. Matching companion APK/RPK signer and physical installation are not accepted. Source debug identity export is outside the source tree; no private key/symlink in source and no release key export.

## Actual native simulator evidence

Official Xiaomi Vela AVD `10Pro`, generic `vela-pre-4.0`, 336 × 480. RPK pushed/unpacked through the toolkit's documented pre-image vapp path, launched in the real VM, and operated through its emulator controller. Screenshots are native emulator pixels, not HTML or generated images. Controller rotation was reset to 0 after a new VM inherited reverse-portrait rotation; no screenshot pixels were manually edited.

The initial runtime attempts exposed blank/compressed content and then repeated-navigation OutOfMemory. Fixes use the official scroll container with non-shrinking children and remove fallback store/transport imports from every page bundle. One app-wide store/transport is accessed through `$app.$def`. RPK reduced from about 94KB to **45,423 bytes**. Final cold-run log covers **12 page creations**, including returns between all five pages, demo on/off and task detail: **no OutOfMemory or TypeError** appeared in this final run. This bounded run does not prove indefinite runtime stability on a physical band. Selected actual lifecycle markers and offline interconnect error are saved in `simulator-final-runtime.txt`.

| Page | Final package native screenshot | Observed behavior |
| --- | --- | --- |
| Home | [home-empty](screenshots/home-empty.png), [navigation](screenshots/home-navigation.png) | Three independent layers; default no data; scroll to four destinations |
| Tasks | [tasks-empty](screenshots/tasks-empty.png), [mock list](screenshots/tasks-mock.png), [mock detail](screenshots/tasks-detail-mock.png) | Local detail expands a long Chinese title, progress and disabled stop; provenance mock remains visible |
| Commands | [commands-empty](screenshots/commands-empty.png) | Default empty, phone registry guidance, execute remains pending integration |
| Devices | [devices-empty](screenshots/devices-empty.png) | Default empty, phone target distinguished from local preview and disabled route change |
| Settings | [settings-empty](screenshots/settings-empty.png), [local settings](screenshots/settings-local.png) | Three layers, W0 diagnostic entry, compact/demo controls, vibration/notification unavailable |

All five final empty screenshots were recaptured using this 45,423-byte shared-instance package. Demo was explicitly enabled in Settings for detail screenshots, then switched off; Home returned to empty. Older invalid/black screenshots were replaced or removed.

## Necessary checks

`node --test test/*.test.js`: **14 passed / 0 failed** (5 existing protocol tests, 5 projection tests, 4 async transport/storage tests). They cover UTF-8 Chinese/emoji budgets and reconstruction/checksum/TTL/bounds; mock/stale/empty/missing provenance; restored cache; lower revisions; local selection vs confirmed target; scope mismatch/revocation; write-before-clear race; durable guard restoration; strict ACK readback and correlated bidirectional Ping/Pong. JavaScript syntax checks passed. Unit/storage harnesses do not claim Xiaomi SDK interoperability.

## Owning-group follow-up

The phone group connects its existing W0 typed messages, authorized AAR adapter, real device permissions/node/app discovery and verified companion-session transitions; the band group calls `store.setScope()` only from that trusted adapter and validates actual W0 persistence/ACK/reconnect on wrist. A scoped snapshot alone does not establish trust. W1/W2/W3 mutations remain disabled until capability, permissions and actual execution results are accepted. Physical signing/install/Ping/Pong/cache restart/background recovery and firmware-specific layout/long-running memory acceptance are still open.

The latest local ADB observation during this work showed Android serial `83626d06` as **device**, model `2210132C` / product `nuwa`; mobile group/root were notified. This is access evidence only, not SDK or wrist acceptance. Do not reuse older authorizing/offline snapshots as current facts.
