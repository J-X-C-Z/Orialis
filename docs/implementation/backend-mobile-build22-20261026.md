# Backend and phone deployment build22

## Scope

This deployment updates the Orialis API, Hermes backends, and Android package. Desktop application binaries are unchanged.

## API

The production API was switched from the 17-type capability set to the preflighted 20-type implementation:

- 20 response UI block types.
- 6 chart kinds.
- Migration ledger and production data snapshot verified before the switch.
- Previous binary retained at `/opt/oris/bin/oris-server.rollback-ui20-20261026`.
- Public health returned `200`; `oris.service` remained active with no restart loop.

## Hermes

Mac, Aozora, and Hakari already had the current adapter, summary helpers, 20-type hint, and final-reply core files. Their hashes match the deployment source and their Orialis gateways remain connected.

Windows had a shared gateway with unrelated active work, so it was not restarted. The current Orialis plugin was written atomically and hot reloaded without changing the gateway PID. The final-reply core files were staged on disk and will load at the next natural gateway restart. All active work was preserved.

## Phone

The Android package is `1.1.2+22` with package ID `top.jxcz.orialis`. It retains the existing signing key.

Phone shell navigation now:

- switches immediately, without a full-screen slide/fade animation;
- keeps inactive branch widgets, navigator state, drafts, and scroll positions mounted;
- pauses hidden branch tickers, pointer handling, focus, semantics, and painting;
- preserves the bottom navigation's own recess/glass-lens motion.

The package is built and verified but not installed because no Android device was connected. Installation remains `adb install -r` so the existing account and database are preserved.

## Verification

Per the user's request, no extended regression suite or performance benchmark was run. Static analysis of the changed navigation files passed, and the release APK built successfully. Deployment checks covered service health, API capabilities, file hashes, plugin reload, gateway PID, active-work preservation, APK manifest, and signing certificate.

Evidence is under `deliveries/backend-mobile-build22-20261026/`.
