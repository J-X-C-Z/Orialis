package top.jxcz.orialis

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

internal object ScheduleLiveTracking {
    private const val CHANNEL = "schedule_tracking"
    private const val TAG = "orialis:schedule-tracking"
    private fun file(context: Context) = AtomicFile(File(context.filesDir, "schedule_tracking_v1.json"))
    private fun read(context: Context): JSONObject? = try {
        JSONObject(file(context).openRead().use { it.readBytes().toString(Charsets.UTF_8) })
    } catch (_: Exception) { null }

    fun validateRows(value: Any?): JSONArray {
        val rows = value as? List<*> ?: emptyList<Any>()
        require(rows.size <= 512) { "Too many live schedules" }
        val seen = mutableSetOf<String>()
        return JSONArray().apply {
            for (entry in rows) {
                val row = entry as? Map<*, *> ?: throw IllegalArgumentException("Invalid live schedule")
                val id = row["id"] as? String ?: ""
                val route = row["route"] as? String ?: ""
                val start = (row["startsAtMillis"] as? Number)?.toLong() ?: 0L
                val end = (row["endsAtMillis"] as? Number)?.toLong() ?: 0L
                require(id.isNotBlank() && id.length <= 512 && seen.add(id)) { "Invalid live schedule ID" }
                require(SystemSnapshot.validRoute(route) && route.startsWith("/calendar/schedule/")) { "Invalid live schedule route" }
                require(start > 0 && end > start) { "Invalid live schedule time" }
                put(JSONObject().put("id", id).put("route", route).put("startsAtMillis", start)
                    .put("endsAtMillis", end).put("title", (row["title"] as? String ?: "日程").take(256))
                    .put("allDay", row["allDay"] == true))
            }
        }
    }

    private fun row(context: Context, state: JSONObject): JSONObject? {
        val snapshot = SystemSnapshot.read(context) ?: return null
        if (!snapshot.optBoolean("enabled") || snapshot.optString("scope") != state.optString("scope")) return null
        val rows = snapshot.optJSONArray("liveSchedules") ?: return null
        val now = System.currentTimeMillis()
        return (0 until rows.length()).mapNotNull { rows.optJSONObject(it) }.firstOrNull {
            it.optString("id") == state.optString("eventId") &&
                ScheduleTrackingPolicy.isOngoing(it.optLong("startsAtMillis"), it.optLong("endsAtMillis"), now)
        }
    }

    fun start(context: Context, arguments: Map<*, *>): Boolean = SystemSnapshot.withLock(context) {
        val state = JSONObject().put("scope", arguments["scope"] as? String ?: "")
            .put("eventId", arguments["eventId"] as? String ?: "").put("token", UUID.randomUUID().toString())
        val row = row(context, state) ?: return@withLock false
        if (!allowed(context)) return@withLock false
        clear(context)
        val store = file(context)
        val output = store.startWrite()
        try {
            output.write(state.toString().toByteArray(Charsets.UTF_8))
            store.finishWrite(output)
        } catch (error: Exception) { store.failWrite(output); throw error }
        if (post(context, state, row)) true else { clear(context); false }
    }

    fun stop(context: Context, arguments: Map<*, *>): Boolean = SystemSnapshot.withLock(context) {
        val state = read(context) ?: return@withLock false
        if (state.optString("scope") != arguments["scope"] || state.optString("eventId") != arguments["eventId"]) return@withLock false
        clear(context)
        true
    }

    fun trackedId(context: Context, arguments: Map<*, *>): String? = SystemSnapshot.withLock(context) {
        val state = read(context) ?: return@withLock null
        if (state.optString("scope") != arguments["scope"]) return@withLock null
        if (row(context, state) == null || !allowed(context)) { clear(context); null }
        else state.optString("eventId")
    }

    fun clear(context: Context) = SystemSnapshot.withLock(context) {
        read(context)?.let { state ->
            val pending = pending(context, state, "expire", PendingIntent.FLAG_NO_CREATE)
            if (pending != null) { context.getSystemService(AlarmManager::class.java).cancel(pending); pending.cancel() }
        }
        file(context).delete()
        context.getSystemService(NotificationManager::class.java).cancel(TAG, 0)
    }

    fun refresh(context: Context) = SystemSnapshot.withLock(context) {
        val state = read(context) ?: return@withLock
        val row = row(context, state)
        // notify() is asynchronous; only deleteIntent, not momentary invisibility, means dismissal.
        if (row == null || !post(context, state, row)) clear(context)
    }

    fun receive(context: Context, intent: Intent) = SystemSnapshot.withLock(context) {
        val state = read(context) ?: return@withLock
        if (!ScheduleTrackingPolicy.matchesSession(state.optString("token"), intent.getStringExtra("token"))) return@withLock
        if (intent.action == "expire" && row(context, state) != null) refresh(context)
        else clear(context)
    }

    private fun allowed(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "日程跟踪", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "手动跟踪正在进行的日程"
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            })
            if (manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    private fun pending(context: Context, state: JSONObject, action: String, flags: Int): PendingIntent? =
        PendingIntent.getBroadcast(context, 0, Intent(context, ScheduleTrackingReceiver::class.java).setAction(action)
            .setData(Uri.Builder().scheme("orialis-tracking").authority(context.packageName).appendPath(state.optString("token")).appendPath(action).build())
            .putExtra("token", state.optString("token")), flags or PendingIntent.FLAG_IMMUTABLE)

    private fun post(context: Context, state: JSONObject, row: JSONObject): Boolean {
        if (!allowed(context)) return false
        val end = row.optLong("endsAtMillis")
        val remaining = end - System.currentTimeMillis()
        if (remaining <= 0) return false
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        val stop = pending(context, state, "stop", PendingIntent.FLAG_UPDATE_CURRENT)
        builder.setSmallIcon(R.drawable.ic_system_reminder).setContentTitle(row.optString("title").ifBlank { "进行中的日程" })
            .setContentText("距离结束").setWhen(end).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_EVENT).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(SystemSnapshot.activityPending(context, row.optString("route"), state.optString("scope")))
            .setDeleteIntent(stop).addAction(Notification.Action.Builder(null, "停止跟踪", stop).build())
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(remaining)
        if (Build.VERSION.SDK_INT >= 36) {
            // Public 36.1 extra, encoded directly to keep the existing API 36 compile SDK.
            builder.addExtras(Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
        }
        return try {
            context.getSystemService(NotificationManager::class.java).notify(TAG, 0, builder.build())
            val alarm = context.getSystemService(AlarmManager::class.java)
            val expiry = pending(context, state, "expire", PendingIntent.FLAG_UPDATE_CURRENT)!!
            // API 26+ timeout removes the visible card even when an inexact cleanup alarm is delayed.
            try {
                if (Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()) alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, end, expiry)
                else alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, end, expiry)
            } catch (_: SecurityException) { alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, end, expiry) }
            true
        } catch (_: SecurityException) { false }
    }
}

class ScheduleTrackingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        worker.execute { try { ScheduleLiveTracking.receive(context, intent) } finally { pending.finish() } }
    }
    companion object { private val worker = Executors.newSingleThreadExecutor() }
}
