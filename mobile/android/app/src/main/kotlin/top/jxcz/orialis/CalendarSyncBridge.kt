package top.jxcz.orialis

import android.Manifest
import android.content.ContentProviderOperation
import android.content.ContentValues
import android.content.pm.PackageManager
import android.provider.CalendarContract
import android.provider.CalendarContract.Events as Events
import android.provider.CalendarContract.Calendars as Calendars
import android.provider.CalendarContract.Reminders as Reminders
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone
import java.util.concurrent.Executors

/** Calendar access is opt-in; every mutation is scoped to the selected writable calendar. */
internal class CalendarSyncBridge(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "top.jxcz.orialis/calendar_sync")
    private val worker = Executors.newSingleThreadExecutor()
    private var disposed = false
    private var permissionResult: MethodChannel.Result? = null
    private val permissions = arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
    private fun allowed() = permissions.all { ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "requestPermission") {
                if (allowed()) result.success(true)
                else if (permissionResult != null) result.error("calendar_busy", "正在请求日历权限", null)
                else {
                    permissionResult = result
                    activity.requestPermissions(permissions, 6842)
                }
            } else if (call.method !in setOf("calendars", "events", "put", "delete")) result.notImplemented()
            else worker.execute {
                try {
                    check(allowed()) { "请允许读取和写入系统日历" }
                    val response = when (call.method) {
                        "calendars" -> calendars()
                        else -> {
                            val calendar = id(call, "calendarId")
                            checkWritable(calendar)
                            when (call.method) {
                                "events" -> events(calendar)
                                "put" -> put(calendar, call)
                                else -> { delete(calendar, id(call, "id")); null }
                            }
                        }
                    }
                    activity.runOnUiThread { if (!disposed) result.success(response) }
                } catch (error: Exception) {
                    activity.runOnUiThread { if (!disposed) result.error("calendar_sync_error", error.message, null) }
                }
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != 6842) return
        permissionResult?.success(allowed())
        permissionResult = null
    }

    fun dispose() {
        disposed = true
        permissionResult?.error("calendar_closed", "日历连接已关闭", null)
        permissionResult = null
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    private val resolver get() = activity.contentResolver
    private fun id(call: MethodCall, name: String): Long =
        call.argument<String>(name)?.toLongOrNull()?.takeIf { it > 0 } ?: error("无效的日历标识")
    private fun calendars(): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        resolver.query(Calendars.CONTENT_URI, arrayOf(Calendars._ID, Calendars.CALENDAR_DISPLAY_NAME, Calendars.ACCOUNT_NAME),
            "${Calendars.CALENDAR_ACCESS_LEVEL} >= ?", arrayOf(Calendars.CAL_ACCESS_CONTRIBUTOR.toString()), null)
            ?.use { cursor ->
                while (cursor.moveToNext()) result.add(mapOf("id" to cursor.getLong(0).toString(),
                    "name" to "${cursor.getString(1).orEmpty()} · ${cursor.getString(2).orEmpty()}"))
            } ?: error("无法完整读取系统日历")
        return result
    }
    private fun checkWritable(calendar: Long) {
        resolver.query(Calendars.CONTENT_URI, arrayOf(Calendars._ID), "${Calendars._ID} = ? AND ${Calendars.CALENDAR_ACCESS_LEVEL} >= ?",
            arrayOf(calendar.toString(), Calendars.CAL_ACCESS_CONTRIBUTOR.toString()), null)?.use {
            check(it.moveToFirst()) { "所选日历已移除或不允许编辑" }
        } ?: error("无法检查系统日历")
    }
    private fun reminder(event: Long): Int? {
        resolver.query(Reminders.CONTENT_URI, arrayOf(Reminders.MINUTES), "${Reminders.EVENT_ID} = ?", arrayOf(event.toString()), "${Reminders.MINUTES} ASC")
            ?.use { return if (it.moveToFirst()) it.getInt(0).takeIf { minutes -> minutes >= 0 } else null }
        error("无法读取日历提醒")
    }
    private fun duration(value: String?): Long? {
        if (value.isNullOrBlank()) return null
        val match = Regex("P(?:(\\d+)W)?(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?").matchEntire(value) ?: return null
        val g = match.groupValues
        return ((g[1].toLongOrNull() ?: 0) * 604800 + (g[2].toLongOrNull() ?: 0) * 86400 +
            (g[3].toLongOrNull() ?: 0) * 3600 + (g[4].toLongOrNull() ?: 0) * 60 + (g[5].toLongOrNull() ?: 0)) * 1000
    }
    private fun events(calendar: Long): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        resolver.query(Events.CONTENT_URI, arrayOf(Events._ID, Events.TITLE, Events.DESCRIPTION, Events.EVENT_LOCATION, Events.DTSTART,
            Events.DTEND, Events.ALL_DAY, Events.RRULE, Events.RDATE, Events.DURATION, Events.ORIGINAL_ID, Events.CUSTOM_APP_URI),
            "${Events.CALENDAR_ID} = ? AND ${Events.DELETED} = 0", arrayOf(calendar.toString()), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val event = cursor.getLong(0)
                val start = cursor.getLong(4)
                val end = if (!cursor.isNull(5)) cursor.getLong(5) else start + (duration(cursor.getString(9)) ?: 0)
                result.add(mapOf("id" to event.toString(), "title" to cursor.getString(1).orEmpty(),
                    "description" to cursor.getString(2), "location" to cursor.getString(3), "startAt" to start,
                    "endAt" to end, "key" to cursor.getString(11)?.takeIf { it.startsWith("orialis://calendar/event/") }?.removePrefix("orialis://calendar/event/"), "allDay" to (cursor.getInt(6) != 0), "reminderMinutes" to reminder(event),
                    "recurring" to (!cursor.getString(7).isNullOrBlank() || !cursor.getString(8).isNullOrBlank() ||
                        !cursor.isNull(10) || end <= start)))
            }
        } ?: error("无法完整读取日程，请稍后重试")
        return result
    }
    private fun checkEvent(calendar: Long, event: Long) {
        resolver.query(Events.CONTENT_URI, arrayOf(Events.RRULE, Events.RDATE, Events.ORIGINAL_ID),
            "${Events._ID} = ? AND ${Events.CALENDAR_ID} = ? AND ${Events.DELETED} = 0", arrayOf(event.toString(), calendar.toString()), null)?.use {
            check(it.moveToFirst()) { "系统日程已移除" }
            check(it.getString(0).isNullOrBlank() && it.getString(1).isNullOrBlank() && it.isNull(2)) { "重复日程请在系统日历编辑" }
        } ?: error("无法检查系统日程")
    }
    private fun put(calendar: Long, call: MethodCall): String {
        val key = call.argument<String>("key")?.takeIf { it.matches(Regex("[0-9a-fA-F-]{36}")) }
            ?: error("无效的 Orialis 日程标识")
        val marker = "orialis://calendar/event/$key"
        val suppliedEvent = call.argument<String>("id")?.let { it.toLongOrNull()?.takeIf { id -> id > 0 } ?: error("无效的日程标识") }
        val event = suppliedEvent ?: run {
            val cursor = resolver.query(Events.CONTENT_URI, arrayOf(Events._ID),
                "${Events.CALENDAR_ID} = ? AND ${Events.CUSTOM_APP_URI} = ? AND ${Events.DELETED} = 0",
                arrayOf(calendar.toString(), marker), null) ?: error("无法检查已有日程，请稍后重试")
            cursor.use { if (it.moveToFirst()) it.getLong(0) else null }
        }
        if (event != null) checkEvent(calendar, event)
        val start = call.argument<Number>("startAt")?.toLong() ?: error("缺少开始时间")
        val end = call.argument<Number>("endAt")?.toLong() ?: error("缺少结束时间")
        check(end > start) { "结束时间必须晚于开始时间" }
        val allDay = call.argument<Boolean>("allDay") == true
        if (allDay) check(start % 86400000L == 0L && end % 86400000L == 0L) { "全天日程需要 UTC 日期边界" }
        val title = call.argument<String>("title")?.trim().orEmpty()
        check(title.isNotEmpty()) { "日程标题不能为空" }
        val values = ContentValues().apply {
            put(Events.CALENDAR_ID, calendar); put(Events.TITLE, title)
            put(Events.DESCRIPTION, call.argument<String>("description")); put(Events.EVENT_LOCATION, call.argument<String>("location"))
            putNull(Events.DURATION)
            put(Events.DTSTART, start); put(Events.DTEND, end); put(Events.ALL_DAY, if (allDay) 1 else 0)
            put(Events.EVENT_TIMEZONE, if (allDay) "UTC" else TimeZone.getDefault().id)
        }
        // Preserve third-party metadata when updating an imported native event.
        if (suppliedEvent == null) values.put(Events.CUSTOM_APP_URI, marker)
        val minutes = call.argument<Number>("reminderMinutes")?.toInt()
        check(minutes == null || minutes >= 0) { "无效的提醒时间" }
        values.put(Events.HAS_ALARM, if (minutes != null) 1 else 0)
        val operations = arrayListOf<ContentProviderOperation>()
        if (event == null) operations.add(ContentProviderOperation.newInsert(Events.CONTENT_URI).withValues(values).build())
        else {
            operations.add(ContentProviderOperation.newUpdate(Events.CONTENT_URI).withSelection("${Events._ID} = ? AND ${Events.CALENDAR_ID} = ?",
                arrayOf(event.toString(), calendar.toString())).withValues(values).withExpectedCount(1).build())
            operations.add(ContentProviderOperation.newDelete(Reminders.CONTENT_URI).withSelection("${Reminders.EVENT_ID} = ?", arrayOf(event.toString())).build())
        }
        if (minutes != null) {
            val op = ContentProviderOperation.newInsert(Reminders.CONTENT_URI).withValue(Reminders.MINUTES, minutes).withValue(Reminders.METHOD, Reminders.METHOD_ALERT)
            if (event == null) op.withValueBackReference(Reminders.EVENT_ID, 0) else op.withValue(Reminders.EVENT_ID, event)
            operations.add(op.build())
        }
        val results = resolver.applyBatch(CalendarContract.AUTHORITY, operations)
        return event?.toString() ?: results[0].uri?.lastPathSegment ?: error("未返回新日程标识")
    }
    private fun delete(calendar: Long, event: Long) {
        checkEvent(calendar, event)
        check(resolver.delete(Events.CONTENT_URI, "${Events._ID} = ? AND ${Events.CALENDAR_ID} = ?", arrayOf(event.toString(), calendar.toString())) == 1) {
            "系统日程未能删除，请重新同步"
        }
    }
}
