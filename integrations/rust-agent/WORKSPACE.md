# Explicit workspace and terminal transport

Implemented from Orialis commit `f9a064bf05b18265afd26905e7240777d4ce355c`, `integrations/hermes/orialis/workspace.py` and `protocol/agent-gateway/workspace-v1.md`.

## API and authorization boundary

`WorkspaceService::from_json(&str)` accepts the original JSON array of `{path,name?,terminal?}`. Empty input or `[]` exposes nothing. There are at most 32 roots, each an explicitly configured existing absolute directory. `WorkspaceService::new(Vec<WorkspaceConfig>)` is the typed equivalent. The optional host-only `new_with_shell(config, absolute_shell_path)` can select a deliberately isolated shell for tests or deployment. Configuration order determines `w0`, `w1`, etc. Capabilities expose names and IDs, not absolute host paths.

Call `handle(conversation_id, trusted_socket_id, &payload).await`, which returns exactly `{ok:true,data:...}` or `{ok:false,error:{code,message}}`. The authenticated Orialis routing layer must first validate the conversation owner, non-deleted state, exact agent binding and request origin. The socket identity is a separate API argument. Payload `_clientId` values never authorize access. When decoding a server frame, only the field verified as injected by the authenticated server may supply that separate argument; do not accept a free-form model or client payload as its source.

`WorkspaceService::response_frame(request_id, conversation_id, result)` creates the correlated `workspace.response` envelope. The gateway must send it only through the requesting server route, without creating model turns, chat events or assistant messages. File bytes and terminal output are direct workspace transport, not LLM tools.

Call `close_client(trusted_socket_id).await` for a trusted socket-disconnect event and `close().await` on plugin/server disconnect or shutdown. Ordinary `handle` requests deliberately reject `terminal.close_client`; internal cleanup is not a mobile operation. A cancelled or timed-out open is guarded before launch and immediately cleans up a shell if launch already completed. A disconnected client also invalidates its pending opens. Other clients' terminals remain separate.

Each request has a 15-second response deadline. File work runs off the async reactor and is serialized through a cancellable semaphore. A cancelled operation that is still queued does not subsequently start. An in-progress OS write cannot be rolled back after a timeout, so timeout errors explicitly tell the caller to inspect the target before retrying. Uploads never overwrite existing targets.

## File contract

- `capabilities`: original operations array, 1 MiB file limit, 256 KiB text limit and workspace terminal flags/reasons.
- `list`: at most 1,000 inspected directory entries, folders first then case-insensitive name order. Links and non-regular special entries are not listed.
- `read`: at most 256 KiB of valid UTF-8 without NUL; returns `path,text,truncated:false`. Escape-heavy text that cannot fit the 1,500,000-byte JSON transport cap returns an explicit `response_too_large` error; download remains available.
- `download`: at most 1 MiB, returning exact `path,name,base64,size`.
- `upload`: strictly decoded base64, at most 1 MiB including empty files, exclusive mode-0600 creation, preserving every existing file. Returns `path,size` after file and directory sync.
- `diff`: workspace-root request path only, tracked changes against a fixed HEAD snapshot, at most 256 KiB with an explicit `truncated` flag.

Unix file operations traverse pinned directory descriptors with `openat` and `O_NOFOLLOW`, not check-then-open string concatenation. Absolute paths, `..`, backslashes/device paths, colons/ADS, NUL and overlong paths are refused. Only regular files can be read; FIFOs cannot block a worker. Repeated directory lists use fresh open descriptions rather than sharing directory offsets. Replacing the original root pathname does not change a pinned file root.

## Protected Git diff

The original Python command's `--no-ext-diff --no-textconv -c core.fsmonitor=false` is insufficient: a repository's `core.worktree` or uploaded `.git` indirection can expose another tree, and a clean/process filter can still execute code. This module does not preserve those unsafe behaviors.

The implementation discovers the physical repository, refuses `.git` symlinks and arbitrary `gitdir` indirection, and validates the reverse pointer for standard linked worktrees. It resolves HEAD with bounded file reads, never by loading repository configuration. A private mode-0700 Git view receives that fixed HEAD, a private copy of the index/shared indexes, and only verified object-directory/file descriptors. It does not expose source `objects/info`, configuration, hooks or info attributes. The working tree is descriptor-backed, and the requested subdirectory remains the pathspec scope. No original repository configuration or global/system configuration is loaded. Staged changes are retained through the index copy.

All Git processes disable external diff, text conversion, filesystem monitoring, lazy fetch and replacement objects; submodule processing is skipped. The total diff operation has a 5-second budget, retains bounded stdout, discards diagnostics, and kills its subprocess group on timeout or failure. Temporary metadata is removed after use. File operations cannot concurrently alter metadata through another request on this same service.

Supported and tested: normal repositories, packed objects/refs, standard linked worktrees, repository-subdirectory scopes, staged changes and raw worktree changes. Object alternates, arbitrary separate-git-dir layouts, external filter transformations, custom executable diff drivers, submodule diff processing, and source-specific configuration transformations are deliberately not applied. Protected diff is Linux-only because it relies on `/proc/self/fd` object/worktree descriptors. Index copies are bounded to 128 MiB total and pack-directory entries to 4,096; exceeding a limit fails explicitly. Large loose-object repositories may reach the fixed 5-second budget rather than bypass validation.

These operations are not an OS sandbox against a hostile process running as the same host UID. Descriptor pinning prevents path replacement from silently selecting a different parent; external mutation of object/file bytes still requires normal host isolation. The terminal capability is an explicit grant of the host account's shell permissions.

## Optional PTY contract

Only `terminal:true` roots can start a shell. At most four terminals exist per service. The initial directory is a pinned allowed workspace path, but commands can access anything allowed to the host account. It is a starting cwd, **not a filesystem sandbox**.

Unix PTYs establish a controlling terminal and a new session, use `TERM=xterm-256color` and `COLORTERM=truecolor`, and implement open/read/write/resize/close. Columns default to 80 and must be 20–300; rows default to 24 and must be 5–120. Input is limited to 8,192 UTF-8 bytes. Output has a 256 KiB bounded buffer and preserves partial UTF-8 sequences. Dropping older output reports `truncated:true`. Escape-heavy output is split across reads without dropping the retained tail so each JSON response fits the transport cap. A blocked write fails after five seconds and warns that some input may already have been written.

A terminal is bound to both conversation and trusted socket identity. Read reports `output,exited,exitCode,truncated` and drains available output. Exited-shell output remains readable until close or expiry. A real 120-second inactivity lease is enforced without requiring another client request. Explicit close, socket disconnect, plugin shutdown and final service drop terminate the shell. On Linux, cleanup also kills every job group still in that PTY session, covering interactive-shell background jobs that are not in the shell's own group. A process deliberately escaping into a separate session is outside this boundary; use OS/container isolation for hostile code.

Linux is the tested platform. Windows protected directory-handle operations, PTY and kill-on-close Job Objects are **not implemented**, and nonempty Windows workspace configuration is rejected rather than falsely advertised. Other Unix PTY/file APIs have not been validated here; Linux-specific Git and job-session cleanup are not claimed portable.

## Reproduction

Run the focused fixture-only suite from the workspace:

```
CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test workspace_transport
```

Tests use disposable directories, local Git repositories, isolated fixture shells with a temporary HOME, and local child processes. They do not read real user directories or connect to a real service. Tests cover disk round-trips, existing-file preservation, path/link/FIFO refusal, repeated list/root replacement, Git truncation/timeout/process-group cleanup, real PTY I/O/resize/exit, scope identity, background-job cleanup, output limits and idle lease. Security regressions cover malicious `.git` upload, `core.worktree`, alternates and `commondir`, executable clean filters, staged state and legitimate subdirectory/linked-worktree handling.

The parent gateway still owns server-authenticated request routing, deleted/revoked conversation denial, wire capability negotiation and response correlation delivery. Local module tests do not replace a complete gateway/mobile end-to-end test.

## Reusable protected filesystem capability

`ProtectedRoot::new(&absolute_path)` pins an explicitly configured root for separate host file tools. `open_file`, `open_dir`, `list`, and `open_parent` reuse this module's descriptor traversal and path checks; listing retains the 1,000-entry bound. `open_parent` returns an existing directory FD and a validated single leaf component for `openat`/`renameat` operations. It never creates missing parent directories. The caller must enforce its own tool authorization, single-link checks, byte/depth quotas, stale-content checks and atomic replacement policy. No PTY/command authority or OS sandbox is conferred. A fixture verifies nofollow/traversal guards, repeated directory iteration and root replacement with descriptor-relative creation.
