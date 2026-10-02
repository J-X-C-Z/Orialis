# Local macOS release

The product path owner runs this workflow after implementing `mobile/macos` and
an explicit desktop entry that excludes chat startup and synchronization.
The wrapper does not create a host or choose a default mobile entry.

From the authoritative repository root:

```bash
bash desktop/build-macos-release.sh --check lib/<desktop-entry>.dart
bash desktop/build-macos-release.sh lib/<desktop-entry>.dart
```

Replace the placeholder with the actual entry accepted by the product owner.
The check only confirms that the host project and entry exist; it does not
certify non-chat isolation. The build requires a writable Paperclip run scratch
directory, as described in [the toolchain handoff](macos-toolchain.md).
It resolves dependencies and builds the existing app, so the invoking owner
must be authorized to modify generated files under `mobile/`.

Successful builds must contain arm64 and pass verification of the existing code
signature. Each run writes a separate `desktop/dist/<timestamp>-<pid>/` containing
`Orialis-macos.zip`, `SHA256SUMS`, and `build-evidence.txt`. This output persists
after run scratch is cleaned. The evidence records HEAD and local modifications;
it does not imply a clean or committed release baseline. No Developer ID signing
or notarization is performed by this wrapper.

For local installation, extract the archive in a writable location, then open
the extracted application in Finder. Retain the build evidence with the archive.
Before handing it to the user, verify actual launch, offline task creation and
restart persistence, account/session behavior, and absence of chat requests.
The full approved product matrix and real phone-to-desktop sync require separate
acceptance evidence. Compilation and signature verification alone do not satisfy
those checks.

## Current evidence — 2026-10-01

The product host and `lib/main_desktop.dart` now exist. A real release build
completed with Xcode 27.0 and Flutter 3.47.4; the universal arm64/x86_64 application
passes `codesign --verify --deep --strict`. The archive at
`desktop/dist/20261001T045132Z-69196/Orialis-macos.zip` was extracted and launched
on this Mac. Existing local data remained visible after restarting the app.

For this local adhoc build, the desktop entry uses the classic macOS login
Keychain through `MacOsOptions(usesDataProtectionKeychain: false)`, with no shared
Keychain access group. The sandbox and network-client entitlement remain enabled.
The empty sharing group from the initial template required a development
certificate that is unavailable on this Mac. Production signing/notarization and
real account credential recovery remain separate acceptance checks.

The complete mobile test suite passes 175 tests (two isolated live-server tests
are skipped). File-backed account/server isolation tests additionally prove that
tasks, pending outbox records and cursors survive closing/reopening without
crossing scopes. Native UI task creation/restart, the full screenshot matrix and
real phone-to-desktop round trips are still unverified; the app build and existing
data display are not a full JXC-37/JXC-38 acceptance verdict. The delivery record
is `/Users/jxcz/Documents/Codex/2026-10-01/new-chat-4/outputs/Orialis-desktop-delivery.md`.
