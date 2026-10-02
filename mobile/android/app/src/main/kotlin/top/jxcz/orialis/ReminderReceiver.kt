package top.jxcz.orialis

import android.app.Notification
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import java.util.concurrent.Executors

/** Explicit, unexported alarm receiver; starts no Flutter engine. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        worker.execute {
            try { deliver(context.applicationContext, intent) }
            finally { pending.finish() }
        }
    }

    private fun deliver(context: Context, intent: Intent) {
        val (snapshot, row) = SystemSnapshot.reminder(context, intent) ?: return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return
        SystemSnapshot.ensureChannel(context)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, SystemSnapshot.CHANNEL)
            else Notification.Builder(context)
        val publicNotice = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, SystemSnapshot.CHANNEL)
            else Notification.Builder(context))
            .setSmallIcon(R.drawable.ic_system_reminder).setContentTitle("Orialis 提醒")
            .setContentText("解锁后查看详情").build()
        builder.setSmallIcon(R.drawable.ic_system_reminder)
            .setContentTitle(row.optString("title")).setContentText(row.optString("body"))
            .setStyle(Notification.BigTextStyle().bigText(row.optString("body")))
            .setCategory(Notification.CATEGORY_REMINDER).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicNotice).setAutoCancel(true)
            .setContentIntent(SystemSnapshot.activityPending(context, row.optString("route"), snapshot.optString("scope")))
        // Root owns the official Xiaomi template adapter; its provider call runs on this worker.
        val originalExtras = Bundle(builder.extras)
        try { XiaomiFocusAdapter.addExtras(context, builder, row, snapshot.optString("scope")) }
        catch (_: Exception) {
            // A broken/unsupported vendor extension must never suppress a normal reminder.
            builder.setExtras(originalExtras)
            if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(0)
        }
        val notice = builder.build()
        SystemSnapshot.withLock(context) {
            // An account change/edit may have happened while Xiaomi permission was queried.
            val current = SystemSnapshot.reminder(context, intent) ?: return@withLock
            if (current.second.toString() != row.toString()) return@withLock
            try { manager.notify("orialis:${snapshot.optString("scope")}:${row.optString("key")}", 0, notice) }
            catch (_: SecurityException) { /* Permission may be revoked between the check and notify. */ }
        }
    }

    companion object { private val worker = Executors.newSingleThreadExecutor() }
}

/** Only the OS delivers boot/time/permission lifecycle broadcasts to this exported receiver. */
class SystemRestoreReceiver : BroadcastReceiver() {
    companion object { private val worker = Executors.newSingleThreadExecutor() }
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
                "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED")) return
        val pending = goAsync()
        worker.execute {
            try {
                if (intent.action == Intent.ACTION_TIMEZONE_CHANGED) SystemSnapshot.rebaseTaskTimezone(context)
                else SystemSnapshot.restore(context)
                TodayWidgetProvider.requestRefresh(context)
            } finally { pending.finish() }
        }
    }
}
