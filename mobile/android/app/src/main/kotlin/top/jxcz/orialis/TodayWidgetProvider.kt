package top.jxcz.orialis

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Runs in :widgetProvider. Disk projection only; no Flutter, network, or database. */
class TodayWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        update(context, manager, ids)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == "${context.packageName}.REFRESH_TODAY_WIDGET") {
            val manager = AppWidgetManager.getInstance(context)
            update(context, manager, manager.getAppWidgetIds(ComponentName(context, TodayWidgetProvider::class.java)))
        }
    }

    companion object {
        fun requestRefresh(context: Context) {
            context.sendBroadcast(Intent(context, TodayWidgetProvider::class.java)
                .setAction("${context.packageName}.REFRESH_TODAY_WIDGET"))
        }

        private fun update(context: Context, manager: AppWidgetManager, ids: IntArray) {
            // Always open the atomic file. SharedPreferences cache is unsafe across processes.
            val snapshot = SystemSnapshot.read(context)
            val scope = if (snapshot?.optBoolean("enabled") == true) snapshot.optString("scope") else ""
            val widget = snapshot?.optJSONObject("widget")
            val currentDate = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
            val fresh = scope.isNotBlank() && widget?.optString("date") == currentDate
            val lines = widget?.optJSONArray("lines")
            val content = if (fresh && lines != null && lines.length() > 0) {
                (0 until minOf(lines.length(), 5)).joinToString("\n") { lines.optString(it) }
            } else if (scope.isBlank()) "打开 Orialis，启用桌面今日卡片"
                else if (!fresh) "打开 Orialis，更新今日内容"
                else "今天暂时没有待办或日程"
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            views.setTextViewText(R.id.widget_date, currentDate)
            views.setTextViewText(R.id.widget_title, if (fresh) widget?.optString("title", "今日") else "Orialis · 今日")
            views.setTextViewText(R.id.widget_lines, content)
            val route = widget?.optString("route", "/today")?.takeIf { it in setOf("/today", "/calendar", "/events") } ?: "/today"
            views.setOnClickPendingIntent(R.id.widget_root, SystemSnapshot.activityPending(context, route, scope))
            for (id in ids) manager.updateAppWidget(id, views)
        }
    }
}
