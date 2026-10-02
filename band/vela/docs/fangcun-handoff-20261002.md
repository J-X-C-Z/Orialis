# 方寸 UI baseline handoff — TASK-023 / 2026-10-02

Source: user / 2026-10-02, COORD-019, actual band source/build/check outputs. Owner Role: orialis-band-coder. Edits restricted to `band/**`; Fangcun reference tree read-only.

## Delivered

Home / new Menu / Tasks / Commands / Devices / Settings / W0 diagnostics use the Fangcun black/circular glyph/compact list language. Header 27px, main titles 23px, notes 16px, cards #191d22/radius20/padding16/gap12, menu/settings rows #1b1f24/radius18/82px/gap10. Device widths use 100%/flex, not Fangcun's fixed 300px. CSS line glyphs need no image assets or external font.

Home is task-first, with phone-confirmed target and three independent connection summaries. Sources remain explicit empty/mock/stale/live; full provenance/sync time moves to footers/settings. No static clock. Menu four routes are navigation only. Task/command details and confirmation explanation remain local, all execution/stop/remote target switching disabled. Settings offers local compact/demo toggles, unavailable vibration/notification, cache clear and diagnostics. Compact changes list note density; demo resets on restart.

The shared app keeps a capped route-name trail; router.replace releases previous page instances. Returning from Home → Tasks goes Home; Menu → Tasks goes Menu; details right-swipe closes detail first. Only cardinal horizontal swipe events route. Details refresh by ID on each store notification, clear on removal/identity revocation/demo end. Store/transport stay app-owned, with no page fallback require/import of transport or store. Scope revoke and operationsEnabled=false stay intact. No new transport or wire business action.

## Verification

- `npm test` at 2026-10-02 21:48 +08:00: 17 passed, 0 failed. Initial baseline was 14; independently existing concurrent changes added 2 page detail checks and 1 durable guard check. This UI worker added no test files. The two detail failures were fixed in shared page subscription; malformed guard was fixed by its existing owner before the final run.
- `npm run build`: success with official AIoT-toolkit 2.0.5, Node v26.8.1. Final compiler completion 21:55:16 +08:00.
- Manifest 0.2.1-ui / versionCode 3.
- RPK `band/vela/dist/top.jxcz.orialis.debug.0.2.1-ui.rpk`: 64786 bytes. SHA-256 `c7855ce7f49b3e214a67c7e916040d17d7cf309549e2933e0b2ea9572508bf94`.
- Default toolkit development signer; APK/RPK matching-signature and physical SDK acceptance remain unverified. No credentials exported.

## Root AIoT IDE acceptance remaining

This worker performed no GUI/touch/screenshot/simulator CLI operation. Root owns final IDE review on true 336×480 Vela: empty Home/menu/subpages readability; Home/menus horizontal gestures and vertical scroll separation; Settings demo ON yields visible mock and actual counts; task and command details/confirmation have disabled execution; device highlight never changes phone target; repeated route switching has no heap exhaustion. Review glyph borders, flex text wrapping, toggle alignment, actual 44px back hit zone and bottom content reachability. Existing screenshots in `docs/screenshots` are previous 0.2.0-ui evidence until new captures are recorded.

Physical SDK discovery, matching-signer install, wrist Ping/Pong and verified phone snapshot/session transitions remain separate open gates.

## Final wording polish

Root's IDE review confirmed Home rendering and Home → Menu left swipe. The view's sourceShort/provenance now use only Chinese UI copy: empty → 无数据; local mock → 演示数据/不执行操作; phone mock → 手机演示数据/只读; stale → 缓存数据/只读; live → 手机同步/只读. Settings demo hint is 本地预览/重启后关闭. Wire dataState and internal mock/stale booleans remain unchanged. Existing source assertions were updated to Chinese copy plus explicit mock boolean checks; no new test case or scope. Version and transport unchanged by wording polish. Other pages and physical gates still require root acceptance.

## Settings first-screen priority

After root's actual 336×480 IDE feedback, Settings places local compact/demo toggles immediately after the connection summary, then the connection diagnosis row. The diagnosis subtitle is 检查手机连接; full W0/Ping technical detail remains in the diagnostics page. This final adjustment changes only settings.ux, preserves unavailable operations and existing toggle behavior, and is followed by a build.
