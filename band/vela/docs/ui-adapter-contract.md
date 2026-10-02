# Optional wear UI projection

Source: TASK-023 user / 2026-10-02 and inter-group implementation coordination.

This is a band view-model input adapter, **not** a new RPC/schema freeze or a declaration that live Tasks/Commands/Devices are integrated. The existing `orialis.wear.v1` snapshot.part envelope, UTF-8 checksum and `snapshot.ack {transferId,revision}` stay compatible. A W0 snapshot with only transferId/revision/title remains valid and shows a summary plus empty business lists.

Optional input shape (local projection):

```json
{
  "transferId": "phone-ui-1",
  "revision": 1,
  "title": "工作区摘要",
  "scope": {"accountId": "opaque-user", "sessionId": "opaque-session", "targetId": "opaque-node"},
  "view": {
    "dataState": "live",
    "updatedAt": "2026-10-02T20:30:00+08:00",
    "targetId": "opaque-node",
    "states": {"phone": "online", "orialis": "unknown", "target": "offline"},
    "tasks": [{"id": "t-1", "title": "查看构建结果", "status": "failed", "summary": "请在手机查看日志", "progress": 72}],
    "commands": [{"id": "c-1", "title": "查看状态", "status": "waiting", "summary": "等待手机回报"}],
    "devices": [{"id": "opaque-node", "name": "MacBook Air", "platform": "macOS", "status": "offline"}]
  }
}
```

Connection enums: online/offline/unknown; invalid and missing values become unknown. Phone is independently derived from current transport, not inferred from snapshot. Orialis/Target are supplied states; Pong does not promote them online. `dataState` accepts live/stale/mock/empty; absent/unknown is conservatively stale. Restore always makes a non-mock snapshot stale. Supplied mock remains visibly mock; local demo stays separate from real persistence. Empty suppresses business lists. UpdatedAt is only a supplied timestamp, not proof of freshness. A missing restore time is “上次同步时间未知”.

Task status: running/working/pending/waiting/done/failed/cancelled. Command status: ready/confirming/waiting/done/failed/unavailable; done is labelled “手机回报完成” and cannot be produced locally by an action button. Unknown statuses display unknown. Up to 20 entries per list are projected; text is bounded and list titles shortened before detail expansion.

`store.setScope(scope)` is the future **verified companion-session adapter** hook. It requires accountId/sessionId and optional targetId. Any account/session/target transition clears the in-memory projection, increments generation, writes a durable cache guard and deletes the persisted snapshot after any in-flight write. Wrong-scope and older revisions are rejected before persistence. `setScope(null)` revokes, blocks input, persists revocation and clears disk. `resetCache()` clears only cache without changing the current trusted scope. Startup restores the guard before the snapshot; a revoked or mismatched cache is never displayed. The serial write/clear queue prevents late persistence from resurrecting old account data. This hook is implemented but **no authenticated phone session transition source has yet been connected**; UI labels that limitation and operations are always disabled. A raw scoped snapshot alone does not establish trust.

Devices selectPreviewTarget() modifies the local highlight only, never view.targetId or the phone-confirmed target. Commands/task stop/Agent control/approvals have no dispatch method or replay queue. W0 Ping/Pong is bidirectional; only a matching pending pingId ends a wait, which times out at 10 seconds. ACK is sent only after validated complete snapshot write and exact string readback.

Page scripts consume the app-wide store via `$app.$def.wearStore`; they do not open SDK connections. One transport at app lifecycle owns interconnect/storage. Page destruction unsubscribes view listeners; app destruction clears pending Ping and transfer timers and detaches transport callbacks.

Next owning-group integration: verify companion handshake/session source, identity transition notifications, actual phone business projections, supported capabilities and real-device results before introducing any mutation RPC or enabling an operation. Pairing, permissions, command idempotency, approvals and background delivery retain the W0/W1/W3/W4 acceptance gates.

Startup acceptance gate (leader review 2026-10-02): snapshot input is rejected without write/ACK until the durable cache guard is read and validated. Guard read/parse failures keep the gate closed. Cache invalidation closes it until the current generation guard write and snapshot deletion succeed. An empty guard preserves legacy W0; it does not establish a trusted companion session. Ping/Pong remain available. The phone may explicitly retry read-only snapshots once ready; sensitive operations have no replay path.
