# ORI-66 Linux path and headless container baseline

Scope: platform preparation for the already frozen `multidevice-v1` 1.0.0. This adds no protocol, route, pairing, key, credential, or authentication behavior. The rooted path helper is isolated in `orialis-server/src/platform_paths.rs`; it is not wired to upload/API handling, so existing application behavior is unchanged.

## Path boundary

`RootedPaths` requires an explicit root and canonicalizes it. Relative inputs must consist only of normal path components; absolute paths, `.` and `..` are rejected. Existing targets and parent directories for new leaf files are canonicalized and checked beneath the root, which rejects symlink escapes. A new leaf must not already exist; the eventual writer should use exclusive creation (`create_new`) and the configured root must also be owned/restricted by the service OS account. The helper documents that path resolution plus a later open is not atomic against a concurrent filesystem attacker. Do not expose arbitrary client-selected paths through this module.

## Headless container files

- `Dockerfile.headless`: multi-stage release build and non-root runtime user (UID 10001).
- `compose.headless.yaml`: read-only container root, only `/data` writable, loopback-only port publication, dropped Linux capabilities, no-new-privileges and bounded `/tmp`.
- `scripts/platform/linux-headless-check.sh`: refuses to represent non-Linux/Docker execution as acceptance; prints host details, Docker version, compose config/build, startup logs, mount permissions and health response.

Run on a Linux Docker/Compose runner from repository root:

```sh
rustc --edition=2021 --test orialis-server/src/platform_paths.rs -o /tmp/orialis-platform-paths-tests
/tmp/orialis-platform-paths-tests
scripts/platform/linux-headless-check.sh
```

The second command leaves its raw build/startup output in the invoking runner log. It creates `runtime-data/` for the bind mount; preserve that runtime data and logs as runner artifacts when conducting acceptance.

## Verification record

Local execution host: `Darwin JXCZdeMacBook-Air.local 27.0.0 Darwin Kernel Version 27.0.0 ... arm64` (macOS ARM64). Rust: `rustc 1.98.1`, Cargo `1.98.1`. `command -v docker` returned no path (Docker CLI unavailable).

Reproducible local command:

```sh
rustc --edition=2021 --test orialis-server/src/platform_paths.rs -o "$PAPERCLIP_RUN_SCRATCH_DIR/platform_paths_tests" && "$PAPERCLIP_RUN_SCRATCH_DIR/platform_paths_tests"
```

Raw result: `running 3 tests`; traversal/absolute path rejection, in-root/new target handling, and Unix symlink escape rejection all `ok`; `test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`.

Linux/container result: **not run**. Invoking the check script on this host intentionally exits 2 with `SKIP: Linux/Docker acceptance requires a Linux runner; detected Darwin arm64`. No Linux or Docker behavior is claimed. A Linux Docker-enabled runner remains required to capture its OS/architecture, image build, mount/permission behavior and raw logs. Existing ORI-54/55 authenticated integration dependencies remain for reconnection; this work does not claim Node/Control completion.

2026-10-03 pre-push review: the build image now uses Rust 1.88 because the checked-in Cargo.lock includes home 0.5.12 and ICU dependencies with rust-version 1.88. The prior 1.86 image could not compile that lockfile. This source-level compatibility correction does not constitute a Docker build or Linux acceptance.
