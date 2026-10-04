# Repository health CI gates

This additive gate set is based on accepted ORI-113 commit
`ff3249beae015557704f7d06404f7fb72a2ecc7d`. It retains ORI-113's already
resolved PR three-dot / push before-after diff range.

## Clippy no-regression baseline

`.github/repo-health/clippy-baseline.json` records compiler diagnostics
captured from `c5d04460df3adf2ffb71ede6530a1c5af85c6dcc` with rustc and Cargo
1.98.1. The command, stored in that file and run by the capture script, is:

```text
cargo clippy --workspace --all-targets --all-features --message-format=json --locked
```

The comparator counts fingerprints by severity, lint code, package and target,
diagnostic message, repo-relative primary file, and normalized primary span
text/label. It deliberately omits line and column positions. New diagnostic
counts fail CI; unchanged diagnostics and removals pass. The cargo process exit
code is propagated, so compiler/process failure cannot become a passing
comparison. This preserves the known findings; this gate does not claim Clippy
is warning-free.

## Changed artifact hygiene

The stdlib-only checker rejects known build/cache/output directories, ignored
local staging/evidence/release outputs, and newly changed compiled application
or object files. It permits generated source, normal product assets, and all
`dist` paths except the repository's specifically ignored local
`mobile/dist/` output. New blobs over 1 MiB require one exact allowlist entry in
`.github/repo-health/large-blobs.json`, with path, Git blob ID, and rationale.
The allowlist is initially empty; it grants no extension-wide exemption.

The unittest fixtures cover unchanged/added/removed/duplicate diagnostics,
Clippy process failure, forbidden output, generated source, a normal product
asset, an unlisted oversized blob, and an exact allowlisted SDK blob. They use
small temporary fixture repositories only.

## Website, Vela, and Lumina CI checks (ORI-114)

The workflow also runs the website install/build, Vela install/unit tests/debug
package build, Lumina Flutter package tests and analysis, its example tests,
the generated-token consistency check, and Lumina Web install/build. These
jobs use Node 22 (meeting Vite's Node 20.19+ minimum) and the stable Flutter
channel (the packages declare Flutter 3.47+ and Dart 3.13+). The workflow has
no path filters, so changes to these package sources, lockfiles, and consumers
continue to trigger the relevant checks on pull requests and configured
branches.

Physical wearable connection, signer matching, Xiaomi SDK behavior, and
watch-side runtime acceptance remain deferred; the CI jobs do not claim device
acceptance. The Vela build only produces the debug RPK under its ignored local
temporary directory and does not use production signing or connect to hardware.

ORI-114 local verification on baseline `e48fa78f6cfdd1c3bbd9254ea2ed26dfc11ba50b`:
website `npm ci && npm run build`, Vela `npm ci && npm test && npm run build`,
Lumina UI `flutter pub get && flutter test` (142 tests) and
`flutter analyze lib test`, showcase `flutter pub get && flutter test` (4
tests), token generator `python3 packages/lumina_tokens/generate_flutter.py
--check`, and Lumina Web `npm ci && npm run build` all exited 0. This is the
matrix command baseline supplied by the coordinating lead; branch-head CI is
still required to verify the workflow wiring.

## Verification record

Execution evidence (the final branch-head SHA is also recorded in the ORI-128
review handoff):

- Base: `ff3249beae015557704f7d06404f7fb72a2ecc7d`.
- Baseline source: `c5d04460df3adf2ffb71ede6530a1c5af85c6dcc`.
- Candidate implementation commit: `a2b7536e16a5361b37eea309541276aac0a13111`.
- Toolchain: rustc `1.98.1 (48a229cea 2026-09-01)`; Cargo
  `1.98.1 (797e8a9bc 2026-08-05)`.
- Baseline and candidate Clippy capture command exit: 0 each; 96
  compiler-message diagnostics captured from each revision. Baseline comparison
  and candidate comparison exit: 0; both report 0 added and 0 removed.
- Fixture command `python3 -m unittest scripts.repo_health.tests.test_gates -v`:
  all 9 pass. Same baseline passes; added warning fails; removed warning
  passes; duplicate warning count detected; cargo failure is propagated;
  forbidden build output fails; generated source and product asset pass;
  unlisted oversized blob fails; exact allowlisted SDK blob passes.
- Range checker command
  `python3 scripts/repo_health/check_changed_artifacts.py --base ff3249beae015557704f7d06404f7fb72a2ecc7d --head a2b7536e16a5361b37eea309541276aac0a13111`:
  exit 0, 7 changed paths checked (rerun during review correction).
- `python3 -m py_compile scripts/repo_health/clippy_diagnostics.py scripts/repo_health/check_changed_artifacts.py scripts/repo_health/tests/test_gates.py` and `git diff --check`: exit 0.
- GitHub Actions workflow run `37210208309` for correction commit
  `052bbeb5d4c70b3bf7c23d415b42b98ce2355a6b`: completed with overall
  conclusion `success`; all five jobs passed, including Clippy diagnostic
  capture and reject-new-diagnostics. This is the GitHub job conclusion; no
  separate workflow run was launched from the local workspace.
- Production calls: none.
- Rollback after commit: `git revert <final-branch-head>` on the task branch.
