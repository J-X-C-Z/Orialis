# Mobile notifications (Android first)

The existing Android system integration remains opt-in and account-scoped. Enabling it in **Profile → System reminders and desktop** allows local schedule reminders and real-time chat notifications. Android 13+ notification permission is requested only from the permission row. A denial, revoked permission, unavailable native bridge, or rejected notification returns a non-success result without interrupting chat/sync.

## Behavior

- Local schedule alarms are projected from the synced local database, keyed by `schedule:<eventId>`. Snapshot replacement cancels changed/deleted alarm PendingIntents before restoring current future alarms; alarms survive process death/reboot. Exact-alarm denial falls back to Android's inexact idle-aware alarm. Notification tap opens `/calendar/schedule/<id>?date=...` after account-scope validation.
- An authenticated realtime `message` envelope is stored locally and offered to Android as a chat notification. Repeated message IDs are ignored; a stable tag/group per conversation replaces the conversation's current notice to limit bursts. Tap opens `/chat?conversationId=<id>&messageId=<id>` and highlights the message when present. Notifications remain in Android's notification history only; the existing chat database is the durable message record.
- `schedule.updated` first requests sync. Only a successful sync refreshes the local alarm projection and emits an update/cancellation notice; offline, authentication and sync errors must not announce a cancellation while the old projection is still present. An updated/deleted schedule therefore replaces or removes its old local alarm by event ID before the update notice is posted.
- Disabling system reminders or switching accounts removes all Orialis reminder, chat and schedule-update notices. Delivery deduplication is account-scoped and is committed only after Android accepts the notification, so a permission failure can be retried.
- Android creates `chat_messages`, `schedule_reminders`, and `schedule_updates` channels, plus reserved `project_updates` and `news_updates` channels. Earlier Android versions use normal notifications without channel controls.

## Test path

1. Enable **开启提醒与桌面**, allow notification permission, then tap **发送测试聊天通知**. The preview selects a locally stored message from a confirmed Mac/Azure Hermes conversation; tapping it opens that conversation and highlights its latest message. Create a device conversation and exchange a message first if none exists. To exercise any specific IDs, call `SystemIntegrationController.notifyChatMessage` with `{id, conversationId, content, sender}`; the method is account-scoped and idempotent.
2. To exercise schedule notice rendering, call `notifyScheduleUpdate` with `{eventId, notificationId, title, startAt, location, action}`. Local alarm registration/update/cancel is tested through schedule CRUD and the existing `SystemIntegrationController.refresh()` projection path.
3. Native test method-channel names `testChatMessage` and `testScheduleUpdate` are available for host-side acceptance harnesses. They share the same permission, scope and payload validation as production.

## Server push contract still required

No APNs/FCM/Mi Push registration or delivery endpoint exists in the current mobile/server contract. A provider-neutral delivery adapter should deliver authenticated, account-targeted envelopes:

```json
{"type":"chat.message","id":"<messageId>","messageId":"<messageId>","conversationId":"<conversationId>","sender":"<sender>","title":"<title>","body":"<body>","createdAt":"<RFC3339>","deeplink":"orialis://chat/<conversationId>?message=<messageId>"}
```

```json
{"type":"schedule.updated","id":"<deliveryEventId>","eventId":"<scheduleId>","action":"created|updated|cancelled","title":"<title>","startAt":"<RFC3339>","location":"<location>","reminders":[{"minutesBefore":15}],"deeplink":"orialis://schedule/event/<scheduleId>"}
```

Delivery IDs must be stable across retries; schedule updates must include the latest schedule version or tombstone so the client can sync before refreshing its projection. The app currently consumes foreground/authenticated realtime envelopes and locally synced schedules; it cannot show chat notices while Android has killed the app until a native push provider and registration/token contract are implemented. The proposed external `orialis://` links are translated to existing internal routes and are not registered as unrestricted Android URI handlers.
