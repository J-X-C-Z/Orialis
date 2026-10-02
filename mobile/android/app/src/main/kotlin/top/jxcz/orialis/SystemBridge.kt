package top.jxcz.orialis

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** All side effects are requested by Dart after the user opts in. */
internal class SystemBridge(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "top.jxcz.orialis/system")
    private var permissionResult: MethodChannel.Result? = null
    private var pendingRoute = SystemSnapshot.routePayload(activity, activity.intent)
    private val worker = Executors.newSingleThreadExecutor()
    private var disposed = false

    init {
        publishShortcuts()
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> readStatus(result)
                    "requestNotifications" -> requestNotifications(result)
                    "openNotificationSettings" -> {
                        val intent = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
                        activity.startActivity(intent)
                        result.success(null)
                    }
                    "openExactAlarmSettings" -> {
                        if (Build.VERSION.SDK_INT >= 31) activity.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                            Uri.parse("package:${activity.packageName}")))
                        result.success(null)
                    }
                    "requestPinWidget" -> {
                        val manager = AppWidgetManager.getInstance(activity)
                        result.success(Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported &&
                            manager.requestPinAppWidget(ComponentName(activity, TodayWidgetProvider::class.java), null, null))
                    }
                    "updateSnapshot" -> {
                        SystemSnapshot.update(activity, call.arguments as? Map<*, *> ?: throw IllegalArgumentException("Invalid snapshot"))
                        result.success(null)
                    }
                    "clear" -> {
                        pendingRoute = null
                        SystemSnapshot.clear(activity)
                        activity.getSystemService(NotificationManager::class.java).cancel("orialis:preview", 0)
                        result.success(null)
                    }
                    "initialRoute" -> {
                        val route = pendingRoute
                        pendingRoute = null
                        result.success(route)
                    }
                    "previewReminder" -> result.success(previewReminder())
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("system_adapter_error", error.message, null)
            }
        }
    }

    private fun publishShortcuts() {
        if (Build.VERSION.SDK_INT < 25 || activity.packageName.endsWith(".news")) return
        val destinations = listOf(Triple("orialis_today", "今日", "/today"),
            Triple("orialis_calendar", "日历", "/calendar"), Triple("orialis_events", "任务", "/events"))
        try {
            activity.getSystemService(ShortcutManager::class.java).dynamicShortcuts = destinations.map { (id, label, route) ->
                ShortcutInfo.Builder(activity, id).setShortLabel(label)
                    .setIcon(Icon.createWithResource(activity, R.drawable.ic_system_reminder))
                    .setIntent(SystemSnapshot.launchIntent(activity, route, "")).build()
            }
        } catch (_: Exception) { /* A launcher may throttle shortcut changes. */ }
    }

    private fun notificationsEnabled(): Boolean =
        (Build.VERSION.SDK_INT < 24 || activity.getSystemService(NotificationManager::class.java).areNotificationsEnabled()) &&
            (Build.VERSION.SDK_INT < 33 || activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    private fun readStatus(result: MethodChannel.Result) {
        val base = mutableMapOf<String, Any>(
            "notificationsEnabled" to notificationsEnabled(),
            "exactAlarmsEnabled" to (Build.VERSION.SDK_INT < 31 || activity.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()),
            "widgetSupported" to (Build.VERSION.SDK_INT >= 26 && AppWidgetManager.getInstance(activity).isRequestPinAppWidgetSupported),
            "manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL, "sdkInt" to Build.VERSION.SDK_INT,
            "xiaomiAppIdConfigured" to try {
                val info = activity.packageManager.getApplicationInfo(activity.packageName, PackageManager.GET_META_DATA)
                !info.metaData?.get("com.xiaomi.xms.APP_ID")?.toString().isNullOrBlank()
            } catch (_: Exception) { false })
        base["focusBusinessConfigured"] = XiaomiFocusAdapter.business(activity).isNotBlank()
        // Xiaomi's provider can block; never query it on the main/UI thread.
        worker.execute {
            val projection = SystemSnapshot.read(activity)
            val rows = projection?.optJSONArray("reminders")
            base["projectedReminderCount"] = rows?.length() ?: 0
            base["activeReminderNotifications"] = if (Build.VERSION.SDK_INT >= 23) {
                activity.getSystemService(NotificationManager::class.java).activeNotifications
                    .count { it.tag?.startsWith("orialis:") == true }
            } else 0
            base["widgetCount"] = AppWidgetManager.getInstance(activity)
                .getAppWidgetIds(ComponentName(activity, TodayWidgetProvider::class.java)).size
            base["focusProtocolVersion"] = try { Settings.System.getInt(activity.contentResolver, "notification_focus_protocol", 0) }
                catch (_: Exception) { 0 }
            base["focusPermission"] = XiaomiFocusAdapter.hasPermission(activity)
            base["hasFocusPermission"] = base["focusPermission"] ?: false
            activity.runOnUiThread { if (!disposed) result.success(base) }
        }
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || notificationsEnabled()) {
            result.success(notificationsEnabled())
            return
        }
        if (permissionResult != null) { result.error("request_in_progress", "Notification permission request is already open", null); return }
        permissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    fun onRequestPermissionsResult(code: Int): Boolean {
        if (code != PERMISSION_REQUEST) return false
        permissionResult?.success(notificationsEnabled())
        permissionResult = null
        return true
    }

    private fun previewReminder(): Boolean {
        if (!notificationsEnabled()) return false
        val snapshot = SystemSnapshot.read(activity) ?: return false
        val scope = snapshot.optString("scope").takeIf { it.isNotBlank() } ?: return false
        SystemSnapshot.ensureChannel(activity)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, SystemSnapshot.CHANNEL) else Notification.Builder(activity)
        val notice = builder.setSmallIcon(R.drawable.ic_system_reminder).setContentTitle("Orialis 测试提醒")
            .setContentText("系统提醒已连接，点击回到今日")
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_REMINDER).setAutoCancel(true)
            .setContentIntent(SystemSnapshot.activityPending(activity, "/today", scope)).build()
        return try { activity.getSystemService(NotificationManager::class.java).notify("orialis:preview", 0, notice); true }
            catch (_: SecurityException) { false }
    }

    fun onNewIntent(intent: Intent) {
        val route = SystemSnapshot.routePayload(activity, intent) ?: return
        // Running Dart owns the identity check; do not also return this intent from initialRoute.
        pendingRoute = null
        channel.invokeMethod("openRoute", route)
    }

    fun dispose() {
        disposed = true
        permissionResult?.error("activity_disposed", "Activity was closed", null)
        permissionResult = null
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    companion object { const val PERMISSION_REQUEST = 7041 }
}
