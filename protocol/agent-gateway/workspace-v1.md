# Hermes workspace transport v1

The phone controls the authenticated Hermes host bound to the owned conversation.
These operations execute directly in the plugin; they never prompt a model.
Neither the server's advertised transport support nor an online Agent proves
that host directories or a terminal are available. Probe `capabilities` first.

## Host configuration

Set the platform's `extra.workspaces` or `ORIALIS_WORKSPACES` to a JSON array:

```json
[{"path":"C:/Work/my-project","name":"My project","terminal":false}]
```

Only existing absolute directories are accepted. The default is `[]`, exposing
no directories. Paths stay on the host; mobile sees `w0`, `w1`, … and display
names. IDs depend on configuration order. After changing host configuration,
reconnect the plugin and re-probe. Terminal access requires `terminal:true` on
that directory and a working PTY. Windows uses the optional installed
`pywinpty` package; Unix uses the standard-library PTY. Missing Windows PTY
support disables terminal capability while retaining file operations.

**Terminal permission grants an interactive shell with the Hermes OS user's
permissions. Its initial working directory is the selected workspace; it is
not a directory sandbox.** Filesystem root restrictions below apply to the
file API, not commands typed into this explicitly enabled shell. Enabling a
terminal must therefore be a deliberate host configuration decision.

## Mobile envelope

Send on the authenticated mobile WebSocket:

```json
{"version":1,"type":"event","request_id":"unique-mobile-id","payload":{"kind":"workspace.request","conversationId":"conv-1","requestId":"unique-mobile-id","op":"list","workspaceId":"w0","path":"src"}}
```

The optional payload `requestId` takes precedence over envelope `request_id`.
Responses are sent only to the requesting socket, with its conversation ID and
request ID even if the user changes the visible conversation:

```json
{"version":1,"type":"event","payload":{"kind":"workspace.response","conversationId":"conv-1","requestId":"unique-mobile-id","op":"list","ok":true,"data":{"entries":[]}}}
```

Failures retain those correlation fields and contain `ok:false` and
`error:{code,message}`. File base64 and terminal output are workspace responses,
not assistant messages or persisted chat events.

## Operations

All paths use `/`, relative to the selected `workspaceId`; root is `""`.

| op | Input fields besides op | data |
|---|---|---|
| capabilities | none | `operations`, `maxFileBytes`, `maxTextBytes`, `workspaces:[{id,name,terminalEnabled,terminalUnavailableReason}]` |
| list | workspaceId, path | `entries:[{name,path,isDirectory,size}]` |
| read | workspaceId, path | `path,text,truncated:false` (UTF-8 text) |
| download | workspaceId, path | `path,name,base64,size` |
| upload | workspaceId, path, base64 | `path,size`; exclusive create, never overwrite |
| diff | workspaceId; root path only | `text,truncated`; tracked changes against HEAD |
| terminal.open | workspaceId, path; optional columns, rows | `terminalId` |
| terminal.write | terminalId, input | `{}` |
| terminal.read | terminalId | `output,exited,exitCode,truncated`; drains buffered output |
| terminal.resize | terminalId, columns, rows | `{}` |
| terminal.close | terminalId | `{}` |

Terminal columns default to 80 (20–300), rows to 24 (5–120). Poll read while
visible (for example every 250–500 ms), feed output unchanged into a terminal
emulator, and send emulator input unchanged to write. Input is limited to 8192
UTF-8 bytes per request. Shells receive `TERM=xterm-256color` and
`COLORTERM=truecolor` even when the Hermes service has no interactive login.
A terminal is bound to both the conversation and the
server-assigned mobile socket identity; another socket cannot take it over.
Close the terminal on panel exit. Socket disconnect closes that socket's shells;
plugin disconnect closes every shell. A 120-second inactivity lease covers lost
connections and unreachable servers. Windows uses a kill-on-close Job Object
for the shell and descendants; Unix terminates the shell's process group.

## Host and gateway frames

The server forwards `workspace.request` with `version`, an internal unique
`request_id`, `conversation_id`, and `payload`. The plugin replies with
`workspace.response` retaining the internal request and conversation IDs plus
`payload:{ok,data}` or `{ok:false,error}`. The server maps back to the phone's ID.
The server exclusively injects `_clientId`. `terminal.close_client` is internal
disconnect cleanup, forbidden as a mobile operation.

The server checks an existing, non-deleted owned conversation and its exact
owned Agent binding. It does not create conversations during workspace access,
fall back to another online Agent, or accept another device's correlated reply.
Requests time out after 15 seconds; replies after timeout are ignored.

## Limits and file safety

Upload/download: 1 MiB per file. Preview/diff: 256 KiB. Terminal output buffer:
256 KiB; if older buffered data is dropped, read reports `truncated:true`.
Directories: at most 1000 entries; larger directories return an explicit error.
The gateway caps workspace JSON payloads at 1,500,000 bytes; the Hermes WebSocket
has a bounded 2 MiB receive limit so the base64 representation of a 1 MiB upload
fits. Git diff disables
external diff drivers, text conversion and filesystem monitor, and times out
after 5 seconds. Untracked files are available through the file browser, not diff.

File APIs reject absolute paths, parent traversal, NUL, Windows alternate streams,
backslash/device paths, symbolic links, junctions and other reparse points.
Only regular files are readable. Windows pins directory handles without delete
sharing while operating, preventing directory replacement. The directories
shared with the plugin should be owned by the same trusted OS user; sharing a
directory is not a substitute for isolating hostile local users at OS level.

On POSIX, parent-directory validation is not an atomic `openat` chain. A local
process able to rename those parents concurrently could race validation. Do not
treat a workspace owned by an actively hostile local user as a strong filesystem
sandbox. POSIX process-group cleanup also cannot contain a program deliberately
escaping into another session. Use OS/container isolation for hostile shell code.

Validation: Python service tests exercise actual disk upload/preview/download,
preserve existing files, reject traversal and junction escape, run real Git diff,
and on a PTY-capable host exercise shell input/output, resize, ownership and
cleanup. Rust tests cover conversation binding and wrong-device reply rejection.
Production and physical-phone acceptance are separate checks.

## Pending mobile interactions

The mobile registry retains only unresolved approval/clarification events in
memory, per authenticated account. On WebSocket hello it atomically subscribes
and snapshots current pending requests, replays their original envelopes, then
continues live events. It retains at most 128 pending requests and 1024 resolved
request tombstones per account. Only a real Hermes `message.ack` with
`status:resolved`, an explicit host resolve, cancellation or approval timeout
removes a pending request. Merely enqueuing a response does not resolve it.
Host errors and ACK timeouts retain the request and allow the same request ID
to be retried; concurrent duplicates are rejected while that ID is in flight.
Rust flat resolves carry conversation scope in `session_id`; Hermes compares it
exactly with the pending conversation before invoking its resolver.
Requests expire after their timeout (default
120 seconds for approval and 300 seconds for clarification). Late duplicate
requests cannot revive a retained resolved ID. This is reconnection recovery,
not durable recovery across a server process restart; host re-emission is still
needed after server restart. Streaming message history is not cached here.
