# Orialis V1 同步

同步分为本地 pending queue、push 和 pull：

1. 用户操作先写入 Drift，界面立即响应；
2. `SyncEngine` 发送带 `Idempotency-Key` 的 HTTP mutation；
3. Rust 在实体变更后写入 `sync_events`，实体版本递增；
4. 客户端用 `after=<cursor>` 拉取增量事件；
5. 删除通过 `deleted_at` 和 `tombstone` 传播。

实体 `version`、用户同步 `cursor` 和旧 Fangcun 文档 `revision` 是三个不同概念。V1 不做 CRDT 或自动合并；服务器返回 409 时，本地修改不能被静默覆盖，后续补冲突处理界面。

首次恢复或游标失效时，使用 `/api/v1/sync/snapshot` 获取完整活动数据。当前 WebSocket 已提供基础连接、heartbeat 和统一 envelope，但仍只是变化提示通道，不能替代 HTTP 状态恢复。
