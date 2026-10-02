package top.jxcz.orialis

import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.provider.Settings
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Optional Xiaomi enhancement; ordinary notifications remain the fallback.
 * Schema: dev.mi.com/xiaomihyperos/documentation/detail?pId=2131 and
 * Xiaomi official template library 2026-01-29, pp. 31, 39, 77, 95, 104.
 * Business must be set to the platform-approved scene, never guessed here.
 */
object XiaomiFocusAdapter {
    fun hasPermission(context: Context): Boolean = try {
        val extras = Bundle().apply { putString("package", context.packageName) }
        context.contentResolver.call(
            Uri.parse("content://miui.statusbar.notification.public"),
            "canShowFocus", null, extras,
        )?.getBoolean("canShowFocus", false) == true
    } catch (_: Exception) { false }

    fun business(context: Context): String = try {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getApplicationInfo(
            context.packageName, PackageManager.GET_META_DATA,
        )
        info.metaData?.getString("top.jxcz.orialis.FOCUS_BUSINESS")?.trim().orEmpty()
    } catch (_: Exception) { "" }

    fun addExtras(
        context: Context,
        builder: Notification.Builder,
        reminder: JSONObject,
        @Suppress("UNUSED_PARAMETER") scope: String,
    ) {
        val business = business(context)
        val version = try { Settings.System.getInt(
            context.contentResolver, "notification_focus_protocol", 0,
        ) } catch (_: Exception) { 0 }
        // Only schedules with a bounded, user-set reminder qualify here.
        if (business.isEmpty() || version < 2 ||
            !reminder.optString("key").startsWith("schedule:") ||
            reminder.optBoolean("allDay", false) || !hasPermission(context)) return
        val now = System.currentTimeMillis()
        val start = reminder.optLong("startsAtMillis", 0)
        val end = minOf(reminder.optLong("endsAtMillis", 0), start + 10 * 60_000L)
        if (start <= 0 || end <= now || end - now > 12 * 60 * 60_000L) return
        val clock = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(start))
        val title = reminder.optString("title").take(120)
        val content = reminder.optString("body").take(200)
        val params = JSONObject().apply {
            put("protocol", 1)
            put("business", business)
            put("filterWhenNoPermission", false)
            put("updatable", false)
            put("timeout", maxOf(1, ((end - now + 59_999) / 60_000).toInt()))
            put("ticker", title)
            put("aodTitle", "$clock $title")
            put("baseInfo", JSONObject().apply {
                put("type", 2); put("title", title); put("content", content)
            })
            put("picInfo", JSONObject().put("type", 1))
            if (version >= 3) put("param_island", JSONObject().apply {
                put("islandProperty", 1)
                put("islandTimeout", maxOf(1, ((end - now) / 1000).toInt()))
                put("bigIslandArea", JSONObject().apply {
                    put("imageTextInfoLeft", JSONObject().apply {
                        put("type", 1)
                        put("picInfo", JSONObject().apply {
                            put("type", 1); put("pic", "miui.focus.pic_orialis")
                        })
                        put("textInfo", JSONObject().put("title", "日程"))
                    })
                    put("textInfo", JSONObject().apply {
                        put("title", clock); put("content", "开始")
                    })
                })
                put("smallIslandArea", JSONObject().put("picInfo", JSONObject().apply {
                    put("type", 1); put("pic", "miui.focus.pic_orialis")
                }))
            })
        }
        val pics = Bundle().apply {
            putParcelable("miui.focus.pic_orialis", Icon.createWithResource(context, R.mipmap.ic_launcher))
        }
        builder.addExtras(Bundle().apply {
            putString("miui.focus.param", JSONObject().put("param_v2", params).toString())
            putBundle("miui.focus.pics", pics)
        })
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(end - now)
    }
}
