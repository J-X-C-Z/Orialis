# Hermes profile sync

Hermes continues to execute on each device. This standalone, standard-library Python tool exchanges only `SOUL.md`, `memories/MEMORY.md`, `memories/USER.md`, and the distributable contents of `skills/`. Authentication, model/device settings, session databases, attachments, cron jobs, machine paths and installed dependencies remain local. A shared skill still needs its dependencies and accounts installed on each device.

This directory contains reusable implementation, tests and placeholder installation templates. It contains no real profile files, personal memories, SOUL content, credentials, hub objects, inventories or production acceptance logs. Hindsight setup and provider credentials are separate and are not configured by this tool.

## Commands and configuration

Copy `profile_sync.py` and, on Windows, `run_sync.py` into a private installation directory. Make a private copy of `templates/config.example.json`; replace every placeholder with local absolute paths, a stable unique `node` name and the chosen SSH destination. Keep the configuration, dedicated SSH key and verified host-key file outside the repository. On Windows use JSON paths with `/` or escaped `\\`; select the locally installed Python/SSH executables.

```sh
python3 profile_sync.py sync --config /absolute/path/to/private/config.json
python3 profile_sync.py hub --store /absolute/path/to/private/hub-store
```

The client sends one JSON frame over SSH; configure the server's dedicated public key with a forced `hub` command. `templates/authorized_keys.example` is a placeholder, not a usable key. Install the hub script on the server, create its private store directory and replace the command paths before adding the key. Do not use a general shell key for this restricted sync channel. Pin the server host key from a trusted source; the sample requires `StrictHostKeyChecking=yes`.

For a local-only setup or test, replace the `ssh` field with `"hub_store": "/absolute/path/to/private/hub-store"`. The `snapshot --profile ...` command emits actual profile contents as base64; its output is private and must not be committed or published.

## Scheduling

Run a successful manual sync first, inspect `status.json` and resolve conflicts before enabling periodic execution.

- **Windows:** place the two scripts plus private `config.json` in `%LOCALAPPDATA%/hermes/profile-sync/orialis`, then explicitly run `install_windows_task.ps1` as the current user. It registers a user task using `pythonw.exe`, on login and every minute, and skips overlapping launches. `run_sync.py` rotates a bounded per-run log beside the installed scripts; keep that folder private. The installer does not modify the Hermes gateway.
- **Linux:** fill the paths/user in the `.service.example` and `.timer.example` templates, install them as `hermes-profile-sync.service`/`.timer` and enable the timer using the appropriate systemd administrator or user scope. Its oneshot service does not overlap itself. Do not leave the placeholder user in an installed unit.
- **macOS:** fill the absolute paths in the `.plist.example` template and install it in the current user's `~/Library/LaunchAgents/` using a unique label. Load it with `launchctl` for that user. LaunchAgent and systemd templates are examples; this repository does not install them automatically.

A one-minute trigger interval is not a guarantee of one-minute propagation: a run can take longer, overlapping runs are skipped, and offline/asleep devices catch up after reconnecting. No scheduler resets or moves running Hermes sessions. Existing conversations may keep their frozen prompt snapshot; new conversations load the updated files.

## Merge, conflicts and recovery

Clients compare live contents to their last applied base, while the hub retains SHA-256 addressed versions. Offline clients do not resurrect unchanged deleted files. Curated memories merge Hermes entries separated by the complete `\n§\n` delimiter. If Git is installed, `git merge-file` merges non-overlapping text edits. Same-region text edits, binary/SOUL conflicts and edit/delete conflicts retain both originals; local live content is not replaced by conflict markers.

Dot metadata, hidden paths, caches, virtual environments, locks and backups under skills are excluded. Local replacements are atomic, memory writes use Hermes-compatible `.md.lock` files, and changed files/skill links have recoverable backups. Linked skills are materialized inside the selected profile before writing so their external shared library is not modified.

`state_dir/status.json` records completion, revision and conflicts. Exit code `0` means completed, `2` means conflicts remain, and `1` means the run failed. The hub can set per-memory character limits in its private `hub.json` `memory_limits` map; over-capacity candidates remain recoverable conflicts rather than being truncated. This package does not change any Hermes configuration or capacity settings.

Stop the sync scheduler before restoring backup files, then reconcile the live profile and hub state deliberately. Client backups are under `state_dir/backups/`; hub objects/history retain source versions. Keep these private. Do not copy actual skills, memory files, state, credentials or hub history into this source directory.

## Validation

From the repository root:

```sh
python3 -m unittest discover -s integrations/hermes/profile_sync -p 'test_*.py'
```

The 15 tests use temporary fixtures only. They cover incremental changes, offline deletion, concurrent memory edits, text merge, SOUL/binary conflicts, scope and case-collision checks, size limits, retry after lost response, real client files and linked-skill materialization. They do not prove a new user's SSH access, schedulers or real-device propagation; those must be checked against that installation.
