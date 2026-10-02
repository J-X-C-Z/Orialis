# Local update review — 2026-10-03

Scope: all intended source updates in the authoritative Orialis checkout, relative to local baseline `7a603220a1e8c4fbedde8d81e7ddcc1a15e2641e`, plus that existing SDK scaffold commit relative to `origin/lumina-ui`. Preserve the existing local `Lumina-UI` branch and push it to `origin/lumina-ui`; this review does not merge main or deploy a service.

## Corrections made during review

1. Hermes resource tools removed `id`, `projectId`, and `conversationId` even when those fields belonged in the request body. Strip only URL placeholders, preserve caller IDs/project relationships, percent-encode path identifiers, and reject missing identifiers before HTTP. Added three regression methods covering these cases.
2. Android system integration adopted an unmarked nonempty shared database on first opt-in. Existing rows have no account attribution. Establish a baseline only for an empty database, observe identity while disabled, and retain a permanent unverified marker across account switches. Two regressions failed before the correction and pass afterward. Existing users with unattributed rows will have projection paused; user consent does not establish ownership.
3. `Dockerfile.headless` used Rust 1.86 although the locked home 0.5.12 and ICU dependencies require 1.88. Set the build image to 1.88; no Docker/Linux execution is claimed.

## Source packaging

Commit source, package locks, migrations, contracts, app assets, the documented Xiaomi SDK AAR, license notices, tests and authored documentation. Keep tool/runtime directories, databases, operational News readbacks, native desktop acceptance captures, generated builds, APK/RPK releases, local editor auto-approval configuration and signing keys on the local machine through ignore rules. Historic documents may refer to these locally retained evidence paths. Pattern-based source scanning found no private key or credential token in the submitted candidate files; this is bounded scanning, not a guarantee about all historical commits.

## Acceptance boundaries

Preserve existing task states for phone/watch interoperability, native multi-device acceptance, production News/Node deployment, and website visual acceptance. Source tests and successful pushes do not complete those tasks. The Vela suite runs without generating signing material. The optional Lumina Web Three.js showcase emits a separate approximately 881 KB chunk (238 KB compressed), an existing performance observation rather than a library build failure.

Concurrent conversation-device routing updates were reviewed too: migration 0017 and owner-scoped GET/PUT binding routes, selected device dispatch, bound-offline behavior without fallback, and the legacy unbound preference path. Three new routing tests passed after the original workspace run, including bound device session/approval commands; latest cargo check passed.

Rust workspace regression: 112 tests passed (core 10, server 73, protocol integration 29); previously reported Node failures did not recur in the default parallel run. Rust formatting was corrected in the changed server modules and its check passes. Contracts: 27 fixtures passed against 12 schemas and the multi-device schemas. Hermes official plugin validation and 39 unit tests passed. Hermes full pytest (including contract fixtures): 49 passed; module paths were verified against this authoritative checkout (old warning paths came from cached bytecode metadata). SDK: 18 passed; News pipeline: 15 passed; News sources: 8 passed. Handheld Vela unit tests: 33 passed. Website and Lumina Web TypeScript/build pipelines passed. Token generated-source consistency and desktop input checks passed.

Flutter component library: 106 passed; showcase: 4 passed. Latest mobile, library and showcase static analysis found no issues. System integration: 11 passed; latest chat/routing/wear targeted checks: 21 passed. Full mobile regression passed 249 and skipped 2, with one test finder ambiguity caused by identical heading/body text; the current News test suite passed all 15 tests separately after correcting that finder.

Final verification results are recorded in the project workspace at `manager/github-push-review-20261003.md` and in the push task record.
