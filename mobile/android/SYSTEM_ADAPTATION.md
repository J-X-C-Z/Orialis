# Android system adaptation

The existing Flutter host keeps Wear and haptics. The `top.jxcz.orialis/system`
channel adds Android reminders, a native today widget, three launcher shortcuts,
and scoped notification/widget navigation. No external SDK or background Flutter
engine is used. This is source implementation; build and device acceptance must
be reported separately.

## Channel contract

- `status`: `notificationsEnabled`, `exactAlarmsEnabled`, `widgetSupported`
  (launcher supports the pin request), `manufacturer`, `model`, `sdkInt`,
  `xiaomiAppIdConfigured`, `focusBusinessConfigured`, `focusProtocolVersion`,
  `focusPermission`/`hasFocusPermission`. Xiaomi provider queries run off the UI
  thread and unsupported devices report false/0.
- `requestNotifications`: requests Android 13+ POST_NOTIFICATIONS only when
  explicitly invoked; returns the actual permission state. A denied request does
  not enable notifications. Concurrent requests are rejected.
- `openNotificationSettings`, `openExactAlarmSettings`: open this app's settings
  when invoked by a user action. Exact alarm permission is never automatically
  requested.
- `requestPinWidget`: returns whether the launcher accepted a widget pin request;
  this is not proof that the user completed placement. Users can also add the
  widget through their launcher's widget picker.
- `updateSnapshot`: requires a nonempty account identity hash `scope`, `enabled`
  (reminders only), `reminders` and `widget`. Bound to 512 reminders / 256 KiB.
  Each reminder has `key`, `title`, `body`, `fireAtMillis`, `route`, and optional
  `startsAtMillis`, `endsAtMillis`, `allDay` for bounded schedule enhancement.
  Task reminders additionally carry `kind: task`, `due`, `dueTime`, and
  `reminderMinutes` so a timezone change can recompute their wall-clock instant.
  Widget has `date` (`yyyy-MM-dd` in the phone's timezone), `title`, `lines`
  (maximum 5), `route`. Call only after user opt-in and a verified identity; never
  send a token, credentials, or unscoped shared database contents.
- `clear`: removes projection, cancels all known alarms/notifications and clears
  widget content. Call on logout, identity changes, and when all system features
  are disabled. Switching identities must clear before replacing the projection.
- `previewReminder`: user-invoked ordinary test notification with fixed generic
  text and `/today` navigation; requires a current projection and notification
  permission. Does not create a task or schedule.
- `initialRoute`: consumes a pending cold-launch `{route, scope}` map once.
  Hot launch calls Dart `openRoute` with the same map. Dart must reject a nonempty
  scope that differs from its current authenticated identity. The native host
  also compares it to the projection. Launcher shortcuts carry an empty scope
  and can only navigate to `/today`, `/calendar`, `/events`.

## Persistence, delivery and privacy

The shared Flutter database has no per-row account attribution. The first
authenticated identity can claim only an empty database; existing rows without
an ownership marker pause system publication, even on first opt-in. Identity
observation starts before opt-in, so changing accounts cannot claim the previous
account's rows. A mismatched or unknown scope remains `identity-unverified`;
enabling the feature does not override that safety check.

An app-private AtomicFile `files/system_projection_v1.json` is the only native
projection. All read/write/delete/restore operations use a reentrant process
lock plus an exclusive FileChannel lock on stable `system_projection_v1.lock`;
the lock inode is never renamed with the AtomicFile. Nested operations share the
outer file lock and do not reacquire it. Every widget read reopens it; it does not rely on multiprocess
SharedPreferences caching. The `:widgetProvider` process renders RemoteViews
without loading Flutter or accessing the Flutter database. An old-day snapshot
shows an update prompt rather than presenting yesterday's entries as today.
Android's periodic widget updates are approximate (30-minute requested period),
so this is a saved last-known projection rather than background live sync.

Reminder alarms use immutable explicit PendingIntents with identity/key URI
uniqueness, and receiver-side identity, key and time validation. Edits/deletions
cancel the previous alarms and changed notifications. A worker revalidates the
whole reminder after optional Xiaomi permission querying and serializes notify
with projection updates/clear to avoid an old-account notification race.
Future alarms are restored after boot, package replacement, clock/timezone
changes and exact-alarm permission grants. Revocation may cancel alarms until
app resume refreshes the projection. Past reminders are never replayed at boot. Dart retains unchanged reminders fired
within the previous 24 hours so ordinary refresh does not immediately remove a
delivered notice; explicit completion/deletion/edit still removes it. Notices
older than that window are removed at the next projection refresh.
Timezone changes strictly reparse Task wall-clock dates/times in the new local
zone and persist new fire times before restoring alarms. Schedule ISO instants
stay unchanged. Invalid task dates/times are removed rather than normalized.
Android 26+ uses java.time; older supported devices use a non-lenient parser.
TIME_SET restores unchanged epoch times.
With exact permission, use `setExactAndAllowWhileIdle`; otherwise use
`setAndAllowWhileIdle`. Android/HyperOS can delay the latter and impose idle
quotas; do not promise exact delivery without permission or device evidence.
Force-stop prevents delivery until the user relaunches the app.

Business alarm and widget receivers are not exported. The exported lifecycle
receiver only handles Android's protected boot/time/package/alarm-permission
broadcasts. MainActivity has no generic app URI scheme registration. Routes are
restricted to existing read-only screens and `/calendar/schedule/<id>?date=...`.
Notifications are VISIBILITY_PRIVATE with generic public lock-screen text.
The desktop widget displays the selected projection to whoever can see the home
screen; its publication therefore requires the app's explicit opt-in.

## Xiaomi and build variants

The standard Android features run independently of Xiaomi approval. The optional
`XiaomiFocusAdapter` uses only official Xiaomi focus/island metadata/templates
and falls back to ordinary notifications without an approved business value,
supported protocol, qualified schedule, or permission. Its code and device
acceptance are owned by the integration lead.

The Gradle properties `-PxiaomiAppId=<public app id>` and
`-PxiaomiFocusBusiness=<approved scene>` populate `com.xiaomi.xms.APP_ID` and
`top.jxcz.orialis.FOCUS_BUSINESS`. `com.xiaomi.xms.BUILD_TYPE_DEBUG` tracks the
build type. Properties default empty and are explicitly blank for news, systemAcceptance and
jointAcceptance packages; no secret or inferred scene value is committed.
Release signing is still the existing configuration and needs independent
production signing review. Existing `newsApp`/`jointAcceptance` IDs and Dart
entry points are retained. Native launcher shortcuts use the runtime package
name, and do not publish Orialis shortcuts in the news-only app.

## Acceptance to perform on a device

1. Enable notifications by user action; decline and retry paths reflect status.
2. Save a future real reminder, edit/delete it, observe only the resulting alarm;
   background the app and observe a delivered notification without Flutter work.
3. Tap task and schedule notices: correct page for the same identity; stale
   account or logout payloads cannot reveal old-account content.
4. Pin/render the widget and tap it; edit today's data, switch account, clear,
   cross midnight and ensure no stale entries are presented as today's data.
5. Long-press the app and test all three shortcut destinations.
6. Inspect restored future reminders after restart/time change; compare exact
   permission with the documented approximate fallback.
7. Verify actual Xiaomi island display separately after approval/whitelist and
   registered signature/APP_ID/business configuration. Ordinary notification
   success is not Xiaomi island acceptance.

Official API sources: [alarm scheduling](https://developer.android.com/develop/background-work/services/alarms),
[notification permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission),
[app widgets](https://developer.android.com/develop/ui/views/appwidgets/overview),
[Xiaomi focus API](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2131),
[Xiaomi admission/configuration](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2132).

Delivery evidence (2026-10-02): see the project-space manager/android-system-adaptation-delivery-20261002.md. Compilation does not confirm device acceptance.
