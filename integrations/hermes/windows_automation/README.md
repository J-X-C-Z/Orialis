# Windows Hermes automation for Orialis

Two optional, read-only utilities for a Hermes profile:

- `orialis_inbox_watch.py` finds user messages newer than an acknowledged watermark. It stores one pending batch until the Hermes task has processed it and explicitly acknowledges the batch. A first run records a starting watermark and does not process older messages.
- `orialis_todo_digest.py` reads tasks and schedules and prints a compact digest for today, tomorrow, and overdue items. It does not send messages itself; configure delivery in Hermes if desired.

Both scripts use Python's standard library. No service or package installation is required.

## Configure a profile

Copy the scripts into the `scripts` directory of the Hermes profile that will run them. The scripts infer the profile directory from that installed location. When running from a checkout or another location, pass `--profile-home <profile-directory>` or set `ORIALIS_HERMES_PROFILE_HOME`.

The profile `.env` file or process environment must provide:

```text
ORIALIS_SERVER_URL=https://<your-orialis-host>
ORIALIS_DEVICE_TOKEN=<device-token>
```

Keep real profile `.env` files and tokens outside source control. Legacy per-script overrides `ORIALIS_INBOX_HOME` and `ORIALIS_DIGEST_HOME` remain supported.

Example PowerShell setup, with the profile name supplied by the operator:

```powershell
$profileHome = Join-Path $env:LOCALAPPDATA 'hermes\profiles\<profile-name>'
$scriptDir = Join-Path $profileHome 'scripts'
New-Item -ItemType Directory -Force $scriptDir | Out-Null
Copy-Item .\orialis_inbox_watch.py, .\orialis_todo_digest.py $scriptDir
```

For one-time manual inspection:

```powershell
python (Join-Path $scriptDir 'orialis_inbox_watch.py') --profile-home $profileHome
python (Join-Path $scriptDir 'orialis_inbox_watch.py') --profile-home $profileHome status
python (Join-Path $scriptDir 'orialis_todo_digest.py') --profile-home $profileHome
```

The inbox scan prints pending message text and attachment names to stdout for the configured Hermes task. Review that data flow and the selected profile before scheduling it. After the task successfully creates or updates the intended Orialis schedules, it must execute the returned `ackCommand`; failed processing leaves the batch pending for retry. Do not acknowledge a batch before its schedule writes succeed.

## Optional Hermes scheduling

Create jobs only after choosing the profile, cadence, task prompt, and delivery destination for your own setup. The following is a command shape with placeholders, not a preconfigured schedule:

```powershell
hermes -p <profile-name> cron create "<cron-expression>" "<task-prompt>" `
  --name "<job-name>" `
  --script orialis_inbox_watch.py `
  --deliver <delivery-target>
```

The inbox job needs the Hermes `cron`, `terminal`, `file`, and Orialis tool access: the script emits candidate messages, the model decides which ones merit schedules, Orialis writes those schedules, and `terminal` runs the acknowledgement command only after success. Configure the digest as a separate no-agent script job if wanted; set its delivery target in Hermes. These utilities do not create, edit, pause, or replace cron jobs themselves.

Inspect and manage jobs through the selected profile's Hermes CLI. To inspect an inbox state, use the `status` subcommand; a non-empty `pendingBatchId` indicates work still awaiting processing or acknowledgement.

## Local mock tests

Run from this directory:

```powershell
python -m unittest -v test_orialis_inbox_watch test_orialis_todo_digest
```

The tests use temporary profile folders and a loopback HTTP mock. They do not contact an Orialis server or send messages.
