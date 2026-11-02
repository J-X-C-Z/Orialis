package top.jxcz.orialis

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Runs in :widgetProvider. Disk projection only; no Flutter, network, or database. */
open class TodayWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, manager, it) }
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        update(context, manager, id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == "${context.packageName}.REFRESH_TODAY_WIDGET") {
            val manager = AppWidgetManager.getInstance(context)
            onUpdate(context, manager, manager.getAppWidgetIds(ComponentName(context, javaClass)))
        }
    }

    companion object {
        data class Kind(val id: String, val provider: Class<out TodayWidgetProvider>, val layout: Int,
                        val title: String, val route: String, val field: String = "lines", val compact: Boolean = false)
        val kinds = listOf(
            Kind("today", TodayWidgetProvider::class.java, R.layout.widget_today, "今日安排", "/today"),
            Kind("today_compact", TodayCompactWidgetProvider::class.java, R.layout.widget_today_compact, "今日概览", "/today", compact = true),
            Kind("today_expanded", TodayExpandedWidgetProvider::class.java, R.layout.widget_today_expanded, "今日总览", "/today"),
            Kind("tasks_compact", TasksCompactWidgetProvider::class.java, R.layout.widget_tasks_compact, "待办速览", "/events", "taskLines", true),
            Kind("tasks", TasksWidgetProvider::class.java, R.layout.widget_tasks, "任务列表", "/events", "taskLines"),
            Kind("tasks_expanded", TasksExpandedWidgetProvider::class.java, R.layout.widget_tasks_expanded, "任务清单", "/events", "taskLines"),
            Kind("agenda", AgendaWidgetProvider::class.java, R.layout.widget_agenda, "接下来", "/calendar", "scheduleLines"),
            Kind("agenda_expanded", AgendaExpandedWidgetProvider::class.java, R.layout.widget_agenda_expanded, "日程列表", "/calendar", "scheduleLines"),
            Kind("month", MonthWidgetProvider::class.java, R.layout.widget_month, "月历", "/calendar"),
            Kind("shortcuts_compact", ShortcutsCompactWidgetProvider::class.java, R.layout.widget_shortcuts_compact, "快捷入口", "/today"),
            Kind("shortcuts", ShortcutsWidgetProvider::class.java, R.layout.widget_shortcuts, "快捷入口", "/today"),
        )

        fun requestRefresh(context: Context) {
            for (kind in kinds) context.sendBroadcast(Intent(context, kind.provider)
                .setAction("${context.packageName}.REFRESH_TODAY_WIDGET"))
        }

        fun widgetCount(context: Context): Int {
            val manager = AppWidgetManager.getInstance(context)
            return kinds.sumOf { manager.getAppWidgetIds(ComponentName(context, it.provider)).size }
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val provider = manager.getAppWidgetInfo(id)?.provider ?: return
            val kind = kinds.firstOrNull { it.provider.name == provider.className } ?: return
            // Serialize publishing with account clear so a receiver cannot republish old data.
            SystemSnapshot.withLock(context) {
                val snapshot = SystemSnapshot.read(context)
                val scope = if (snapshot?.optBoolean("enabled") == true) snapshot.optString("scope") else ""
                val widget = snapshot?.optJSONObject("widget")
                val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
                val fresh = scope.isNotBlank() && widget?.optString("date") == today
                val views = RemoteViews(context.packageName, kind.layout)
                if (kind.id.startsWith("shortcuts")) {
                    val buttons = listOf(R.id.widget_today_action to "/today", R.id.widget_tasks_action to "/events",
                        R.id.widget_calendar_action to "/calendar", R.id.widget_settings_action to "/system")
                    for ((view, route) in buttons) {
                        if (kind.id == "shortcuts_compact" && view !in setOf(R.id.widget_today_action, R.id.widget_tasks_action)) continue
                        views.setOnClickPendingIntent(view, SystemSnapshot.activityPending(context, route, ""))
                    }
                } else {
                    views.setTextViewText(R.id.widget_title, kind.title)
                    views.setTextViewText(R.id.widget_date, SimpleDateFormat("M月d日 EEEE", Locale.CHINA).format(Date()))
                    views.setOnClickPendingIntent(R.id.widget_root, SystemSnapshot.activityPending(context,
                        if (!fresh) "/system" else kind.route, if (fresh) scope else ""))
                    val height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT,
                        if (kind.id.endsWith("expanded")) 280 else 130)
                    if (kind.id == "month") renderMonth(context, views, if (fresh) widget else null)
                    else {
                        val count = if (kind.field == "taskLines") widget?.optInt("taskCount") ?: 0
                            else (widget?.optInt("todayTaskCount") ?: 0) + (widget?.optInt("scheduleCount") ?: 0)
                        views.setTextViewText(R.id.widget_metric, if (fresh) count.toString() else "—")
                        views.setTextViewText(R.id.widget_summary, if (!fresh) "打开 Orialis 设置"
                            else if (kind.field == "taskLines") "项待完成" else "项今日安排")
                        views.setViewVisibility(R.id.widget_metric_group, if (kind.compact && height >= 100) View.VISIBLE else View.GONE)
                        views.setViewVisibility(R.id.widget_rows, if (kind.compact && height < 180) View.GONE else View.VISIBLE)
                        views.removeAllViews(R.id.widget_rows)
                        val rows = if (fresh) widget?.optJSONArray(kind.field) else null
                        val limit = ((height - if (kind.compact) 130 else if (height >= 180) 100 else 75) / 38).coerceIn(1, 12)
                        val empty = if (scope.isBlank()) "打开 Orialis，启用桌面展示"
                            else if (!fresh) "打开 Orialis，更新今日内容"
                            else if (kind.field == "taskLines") "待办已清空，享受此刻"
                            else if (kind.field == "scheduleLines") "未来七天暂无日程" else "今天暂无待办或日程"
                        val texts = if (rows == null || rows.length() == 0) listOf(empty)
                            else (0 until minOf(rows.length(), limit)).map { rows.optString(it) }
                        for (text in texts) {
                            val row = RemoteViews(context.packageName, R.layout.widget_item)
                            row.setTextViewText(R.id.widget_item_text, text)
                            views.addView(R.id.widget_rows, row)
                        }
                        views.setTextViewText(R.id.widget_footer, if (!fresh) "点击设置"
                            else if ((rows?.length() ?: 0) > limit) "查看全部  ↗" else "打开 Orialis  ↗")
                        views.setViewVisibility(R.id.widget_footer, if (height >= 180 && !kind.compact) View.VISIBLE else View.GONE)
                    }
                }
                manager.updateAppWidget(id, views)
            }
        }

        private fun renderMonth(context: Context, views: RemoteViews, widget: JSONObject?) {
            val now = Calendar.getInstance()
            val day = now.get(Calendar.DAY_OF_MONTH)
            views.setTextViewText(R.id.widget_date, SimpleDateFormat("yyyy年M月", Locale.CHINA).format(now.time))
            val marked = widget?.optJSONArray("calendarDays")
            val days = if (marked == null) emptySet() else (0 until marked.length()).map { marked.optInt(it) }.toSet()
            now.set(Calendar.DAY_OF_MONTH, 1)
            val offset = (now.get(Calendar.DAY_OF_WEEK) + 5) % 7
            val last = now.getActualMaximum(Calendar.DAY_OF_MONTH)
            views.removeAllViews(R.id.widget_calendar)
            val ids = listOf(R.id.widget_day_0, R.id.widget_day_1, R.id.widget_day_2, R.id.widget_day_3,
                R.id.widget_day_4, R.id.widget_day_5, R.id.widget_day_6)
            val heading = RemoteViews(context.packageName, R.layout.widget_calendar_week)
            listOf("一", "二", "三", "四", "五", "六", "日").forEachIndexed { index, label -> heading.setTextViewText(ids[index], label) }
            views.addView(R.id.widget_calendar, heading)
            for (week in 0 until (offset + last + 6) / 7) {
                val row = RemoteViews(context.packageName, R.layout.widget_calendar_week)
                for (column in 0..6) {
                    val date = week * 7 + column - offset + 1
                    row.setTextViewText(ids[column], if (date in 1..last) "$date${if (date in days) "·" else ""}" else "")
                    if (date == day) {
                        row.setInt(ids[column], "setBackgroundResource", R.drawable.widget_accent_background)
                        row.setTextColor(ids[column], context.getColor(R.color.widget_on_accent))
                    }
                }
                views.addView(R.id.widget_calendar, row)
            }
            views.setTextViewText(R.id.widget_footer, if (widget == null) "点击设置 · 启用日程标记" else "· 有日程    点击查看日历  ↗")
        }
    }
}

class TodayCompactWidgetProvider : TodayWidgetProvider()
class TodayExpandedWidgetProvider : TodayWidgetProvider()
class TasksCompactWidgetProvider : TodayWidgetProvider()
class TasksWidgetProvider : TodayWidgetProvider()
class TasksExpandedWidgetProvider : TodayWidgetProvider()
class AgendaWidgetProvider : TodayWidgetProvider()
class AgendaExpandedWidgetProvider : TodayWidgetProvider()
class MonthWidgetProvider : TodayWidgetProvider()
class ShortcutsCompactWidgetProvider : TodayWidgetProvider()
class ShortcutsWidgetProvider : TodayWidgetProvider()
