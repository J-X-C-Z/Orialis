package top.jxcz.orialis

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.locks.ReentrantLock

/** Separate, bounded projection. Never reads Flutter's database or credentials. */
internal object SystemSnapshot {
    const val ROUTE = "orialis.system.route"
    const val SCOPE = "orialis.system.scope"
    const val CHANNEL = "schedule_reminders"
    const val CHAT_CHANNEL = "chat_messages"
    const val UPDATE_CHANNEL = "schedule_updates"
    private const val MAX_BYTES = 256 * 1024
    private fun file(context: Context) = AtomicFile(File(context.filesDir, "system_projection_v1.json"))

    private val processLock = ReentrantLock()
    private val lockDepth = ThreadLocal<Int>()

    /** Stable inode: never lock the snapshot itself because AtomicFile replaces it. */
    fun <T> withLock(context: Context, operation: () -> T): T {
        processLock.lock()
        try {
            if ((lockDepth.get() ?: 0) > 0) return operation()
            return RandomAccessFile(File(context.filesDir, "system_projection_v1.lock"), "rw").use { lockFile ->
                lockFile.channel.lock().use {
                    lockDepth.set(1)
                    try { operation() } finally { lockDepth.set(0) }
                }
            }
        } finally { processLock.unlock() }
    }

    fun read(context: Context): JSONObject? = withLock(context) { readUnlocked(context) }

    private fun readUnlocked(context: Context): JSONObject? = try {
        val bytes = file(context).openRead().use { it.readBytes() }
        if (bytes.size > MAX_BYTES) null else JSONObject(String(bytes, Charsets.UTF_8))
    } catch (_: Exception) { null }

    fun validRoute(route: String): Boolean {
        if (route in setOf("/today", "/calendar", "/events")) return true
        if (Regex("^/chat\\?conversationId=[A-Za-z0-9_.~+%-]{1,512}(?:&messageId=[A-Za-z0-9_.~+%-]{1,512})?$").matches(route)) return true
        // Existing read-only Schedule detail route, optionally carrying its local date.
        return Regex("^/calendar/schedule/(?:[A-Za-z0-9_.~+-]|%[A-Fa-f0-9]{2})+(?:\\?date=[0-9TZ:+.%\\-]+)?$").matches(route)
    }

    fun update(context: Context, arguments: Map<*, *>) = withLock(context) {
        updateUnlocked(context, arguments)
    }

    private fun updateUnlocked(context: Context, arguments: Map<*, *>) {
        val scope = (arguments["scope"] as? String)?.takeIf { it.isNotBlank() && it.length <= 1024 }
            ?: throw IllegalArgumentException("A verified account scope is required")
        val reminders = JSONArray()
        val seen = mutableSetOf<String>()
        val input = arguments["reminders"] as? List<*> ?: emptyList<Any>()
        require(input.size <= 512) { "Too many reminders" }
        for (entry in input) {
            val row = entry as? Map<*, *> ?: throw IllegalArgumentException("Invalid reminder")
            val key = row["key"] as? String ?: throw IllegalArgumentException("Missing reminder key")
            val route = row["route"] as? String ?: "/today"
            require(key.isNotBlank() && key.length <= 512 && seen.add(key)) { "Invalid/duplicate reminder key" }
            require(validRoute(route)) { "Invalid reminder route" }
            val at = (row["fireAtMillis"] as? Number)?.toLong() ?: throw IllegalArgumentException("Missing reminder time")
            reminders.put(JSONObject().put("key", key).put("title", (row["title"] as? String ?: "Orialis").take(256))
                .put("body", (row["body"] as? String ?: "").take(1024)).put("fireAtMillis", at).put("route", route)
                .put("startsAtMillis", (row["startsAtMillis"] as? Number)?.toLong() ?: 0L)
                .put("endsAtMillis", (row["endsAtMillis"] as? Number)?.toLong() ?: 0L)
                .put("allDay", row["allDay"] == true)
                .put("kind", (row["kind"] as? String ?: "").take(16))
                .put("due", (row["due"] as? String ?: "").take(32))
                .put("dueTime", (row["dueTime"] as? String ?: "").take(16))
                .put("reminderMinutes", (row["reminderMinutes"] as? Number)?.toLong() ?: -1L))
        }
        val widget = arguments["widget"] as? Map<*, *> ?: emptyMap<Any, Any>()
        val widgetRoute = widget["route"] as? String ?: "/today"
        require(widgetRoute in setOf("/today", "/calendar", "/events")) { "Invalid widget route" }
        val lines = JSONArray()
        (widget["lines"] as? List<*>)?.take(5)?.forEach { lines.put((it as? String ?: "").take(256)) }
        val next = JSONObject().put("scope", scope).put("enabled", arguments["enabled"] == true)
            .put("reminders", reminders).put("widget", JSONObject()
                .put("date", (widget["date"] as? String ?: "").take(32))
                .put("title", (widget["title"] as? String ?: "今日").take(128))
                .put("lines", lines).put("route", widgetRoute))
        val previous = read(context)
        writeUnlocked(context, next)
        // Persist first: a receiver racing this change must only see the new identity.
        cancelAlarms(context, previous, next)
        cancelChangedNotifications(context, previous, next)
        restore(context)
        TodayWidgetProvider.requestRefresh(context)
    }

    private fun writeUnlocked(context: Context, snapshot: JSONObject) {
        val bytes = snapshot.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX_BYTES) { "Projection too large" }
        val store = file(context)
        val output = store.startWrite()
        try {
            output.write(bytes)
            store.finishWrite(output)
        } catch (error: Exception) {
            store.failWrite(output)
            throw error
        }
    }

    fun clear(context: Context) = withLock(context) {
        val previous = read(context)
        file(context).delete()
        cancelAlarms(context, previous)
        cancelNotifications(context, previous)
        TodayWidgetProvider.requestRefresh(context)
    }

    /** Task deadlines are wall-clock values. Schedule instants never move with the timezone. */
    fun rebaseTaskTimezone(context: Context) = withLock(context) {
        val previous = read(context)
        if (previous != null) {
            // Copy before changing rows so old PendingIntents can be cancelled by their saved time.
            val next = JSONObject(previous.toString())
            val valid = JSONArray()
            for (row in rows(next)) {
                if (row.optString("kind") != "task") { valid.put(row); continue }
                val at = taskFireAt(row)
                if (at != null) valid.put(row.put("fireAtMillis", at))
            }
            next.put("reminders", valid)
            writeUnlocked(context, next)
            cancelAlarms(context, previous, next)
            cancelChangedNotifications(context, previous, next)
            restore(context)
        }
        TodayWidgetProvider.requestRefresh(context)
    }

    private fun taskFireAt(row: JSONObject): Long? = try {
        val date = row.optString("due")
        val time = row.optString("dueTime")
        val minutes = row.optLong("reminderMinutes", -1L)
        if (!Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$").matches(date) ||
            !Regex("^[0-9]{2}:[0-9]{2}(?::[0-9]{2})?$").matches(time) || minutes < 0) null
        else {
            val deadline = if (Build.VERSION.SDK_INT >= 26) {
                LocalDate.parse(date, DateTimeFormatter.ISO_LOCAL_DATE)
                    .atTime(LocalTime.parse(time, DateTimeFormatter.ISO_LOCAL_TIME))
                    .atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
            } else {
                // API 24/25 don't ship java.time. This equally strict parser never normalizes bad dates.
                val parser = SimpleDateFormat(if (time.length == 8) "yyyy-MM-dd HH:mm:ss" else "yyyy-MM-dd HH:mm", Locale.US)
                parser.isLenient = false
                parser.parse("$date $time")?.time ?: throw IllegalArgumentException("Invalid task deadline")
            }
            Math.subtractExact(deadline, Math.multiplyExact(minutes, 60_000L))
        }
    } catch (_: Exception) { null }

    private fun alarmIntent(context: Context, scope: String, key: String) = Intent(context, ReminderReceiver::class.java)
        .setAction("${context.packageName}.SYSTEM_REMINDER")
        .setData(Uri.Builder().scheme("orialis-internal").authority(context.packageName).appendPath(scope).appendPath(key).build())
        .putExtra(SCOPE, scope).putExtra("key", key)

    private fun alarmPending(context: Context, scope: String, row: JSONObject, flags: Int): PendingIntent? =
        PendingIntent.getBroadcast(context, 0,
            alarmIntent(context, scope, row.optString("key")).putExtra("fireAtMillis", row.optLong("fireAtMillis")),
            flags or PendingIntent.FLAG_IMMUTABLE)

    private fun rows(snapshot: JSONObject?): List<JSONObject> {
        val array = snapshot?.optJSONArray("reminders") ?: return emptyList()
        return (0 until array.length()).mapNotNull { array.optJSONObject(it) }
    }

    private fun cancelAlarms(context: Context, snapshot: JSONObject?, next: JSONObject? = null) {
        val manager = context.getSystemService(AlarmManager::class.java)
        val scope = snapshot?.optString("scope") ?: return
        val preserveUnchanged = next != null && next.optBoolean("enabled") && next.optString("scope") == scope
        val nextRows = rows(next).associateBy { it.optString("key") }
        for (row in rows(snapshot)) {
            // Inexact alarms may still be queued after their nominal fire time.
            // A routine refresh must not cancel them: restore only registers
            // future rows, so cancelling unchanged overdue rows loses delivery.
            if (preserveUnchanged && nextRows[row.optString("key")]?.toString() == row.toString()) continue
            alarmPending(context, scope, row, PendingIntent.FLAG_NO_CREATE)?.let {
                manager.cancel(it)
                it.cancel()
            }
        }
    }

    private fun cancelChangedNotifications(context: Context, previous: JSONObject?, next: JSONObject) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val sameScope = previous?.optString("scope") == next.optString("scope")
        val nextRows = rows(next).associateBy { it.optString("key") }
        for (row in rows(previous)) {
            if (!sameScope || !next.optBoolean("enabled") || nextRows[row.optString("key")]?.toString() != row.toString()) {
                manager.cancel("orialis:${previous?.optString("scope")}:${row.optString("key")}", 0)
            }
        }
        if (!sameScope) cancelNotifications(context, previous)
    }

    private fun cancelNotifications(context: Context, snapshot: JSONObject?) {
        val manager = context.getSystemService(NotificationManager::class.java)
        for (row in rows(snapshot)) manager.cancel("orialis:${snapshot?.optString("scope")}:${row.optString("key")}", 0)
        // Chat/update notices are not part of the reminder projection. Clear
        // them too when consent or identity changes, including orphaned tags.
        if (Build.VERSION.SDK_INT >= 23) {
            manager.activeNotifications.filter { it.tag?.startsWith("orialis:") == true }
                .forEach { manager.cancel(it.tag, it.id) }
        }
    }

    fun restore(context: Context) = withLock(context) { restoreUnlocked(context) }

    private fun restoreUnlocked(context: Context) {
        val snapshot = read(context) ?: return
        if (!snapshot.optBoolean("enabled")) return
        val manager = context.getSystemService(AlarmManager::class.java)
        for (row in rows(snapshot)) {
            val at = row.optLong("fireAtMillis")
            if (at <= System.currentTimeMillis()) continue
            val pending = alarmPending(context, snapshot.optString("scope"), row, PendingIntent.FLAG_UPDATE_CURRENT) ?: continue
            // No USE_EXACT_ALARM exemption claim. Work with the permission already granted.
            try {
                if (Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()) {
                    manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
                } else manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            } catch (_: SecurityException) {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            }
        }
    }

    fun reminder(context: Context, intent: Intent): Pair<JSONObject, JSONObject>? {
        val snapshot = read(context) ?: return null
        if (!snapshot.optBoolean("enabled") || snapshot.optString("scope") != intent.getStringExtra(SCOPE)) return null
        val row = rows(snapshot).firstOrNull {
            it.optString("key") == intent.getStringExtra("key") && it.optLong("fireAtMillis") == intent.getLongExtra("fireAtMillis", -1)
        } ?: return null
        if (row.optLong("fireAtMillis") > System.currentTimeMillis()) return null
        return snapshot to row
    }

    fun launchIntent(context: Context, route: String, scope: String): Intent = Intent(context, MainActivity::class.java)
        .setAction("${context.packageName}.OPEN_SYSTEM_ROUTE")
        .setData(Uri.Builder().scheme("orialis-internal").authority(context.packageName).appendPath(scope).appendPath(route).build())
        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        .putExtra(ROUTE, route).putExtra(SCOPE, scope)

    fun activityPending(context: Context, route: String, scope: String): PendingIntent = PendingIntent.getActivity(
        context, 0, launchIntent(context, route, scope), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun routePayload(context: Context, intent: Intent?): Map<String, String>? {
        val route = intent?.getStringExtra(ROUTE) ?: return null
        val scope = intent.getStringExtra(SCOPE) ?: ""
        if (!validRoute(route)) return null
        if (scope.isBlank()) {
            if (route !in setOf("/today", "/calendar", "/events")) return null
        } else if (read(context)?.optString("scope") != scope) return null
        // Dart also checks its current authenticated scope before opening any detail.
        return mapOf("route" to route, "scope" to scope)
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            ensureChannels(context)
        }
    }

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java)
        listOf(
            Triple(CHAT_CHANNEL, "聊天消息", "Hermes 与 Agent 会话的新消息"),
            Triple(CHANNEL, "日程提醒", "已同步到本机的日程提醒"),
            Triple(UPDATE_CHANNEL, "日程变更", "日程新增、变更或取消"),
            Triple("project_updates", "项目更新", "项目状态与动态"),
            Triple("news_updates", "资讯更新", "Orialis 资讯更新"),
        ).forEach { (id, name, description) ->
            manager.createNotificationChannel(NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH).apply {
                this.description = description
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
            })
        }
    }
}
