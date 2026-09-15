package app.fangcun.fangcun_devtools

<<<<<<< HEAD
import app.fangcun.XiaomiWristbandAdapter
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.AlarmManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import org.json.JSONObject
<<<<<<< HEAD
import org.json.JSONArray
import java.util.concurrent.Executors
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val supportedEvents = setOf("focus.start", "focus.pause", "focus.complete", "course.start", "ddl.remind")
    private val channelName = "app.fangcun/hyperos"
    private val notificationId = 4617
    private val notificationChannel = "fangcun_devtools_island"
    private val snapshotPrefs = "fangcun_devtools_snapshot"
    private lateinit var notifications: NotificationManager
<<<<<<< HEAD
    private lateinit var wristband: XiaomiWristbandAdapter
    private val wristbandExecutor = Executors.newSingleThreadExecutor()
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        notifications = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
<<<<<<< HEAD
        wristband = XiaomiWristbandAdapter(this)
        if (Build.VERSION.SDK_INT >= 26) {
            notifications.createNotificationChannel(NotificationChannel(notificationChannel, "方寸开发者事件", NotificationManager.IMPORTANCE_HIGH))
        }
        if (BackgroundSyncStore.token(this) != null) BackgroundSyncScheduler.schedule(this)
=======
        if (Build.VERSION.SDK_INT >= 26) {
            notifications.createNotificationChannel(NotificationChannel(notificationChannel, "方寸开发者事件", NotificationManager.IMPORTANCE_HIGH))
        }
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "triggerEvent" -> {
                    val args = call.arguments as? Map<*, *>
                    val event = args?.get("event") as? String ?: "debug.event"
                    val payload = (args?.get("payload") as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value } ?: emptyMap()
                    if (!supportedEvents.contains(event)) {
                        result.success(mapOf("ok" to false, "error" to "unsupported_event", "eventSchema" to "fangcun.native.v1"))
                        return@setMethodCallHandler
                    }
                    saveSnapshot(event, payload)
                    val island = showNotification(event, payload)
                    playHaptic(hapticFor(event))
                    result.success(mapOf("ok" to true, "event" to event, "native" to true, "haptic" to hapticFor(event), "island" to island, "capabilities" to capabilities()))
                }
                "getCapabilities" -> result.success(capabilities())
<<<<<<< HEAD
=======
                "getWristbandCapabilities", "getWristbandStatus" -> result.success(wristbandCapabilities())
                "connectWristband" -> result.success(wristbandUnavailable("connect"))
                "disconnectWristband" -> result.success(wristbandUnavailable("disconnect"))
                "syncWristband" -> result.success(wristbandUnavailable("sync"))
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
                "getSnapshot" -> result.success(readSnapshot())
                "haptic" -> {
                    playHaptic((call.arguments as? Map<*, *>)?.get("semantic") as? String ?: "light")
                    result.success(mapOf("ok" to true))
                }
                "saveTodaySnapshot" -> {
                    val args = call.arguments as? Map<*, *>
                    saveTodaySnapshot(args?.mapKeys { it.key.toString() } ?: emptyMap())
                    result.success(mapOf("ok" to true, "native" to true))
                }
                "clearEvent" -> {
                    notifications.cancel(notificationId)
                    saveSnapshot("clear", emptyMap())
                    result.success(mapOf("ok" to true))
                }
                "setDeveloperMode" -> result.success(mapOf("ok" to true, "native" to true))
<<<<<<< HEAD
                "configureBackgroundSync" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val serverUrl = arguments?.get("serverUrl") as? String
                    val token = arguments?.get("token") as? String
                    if (serverUrl.isNullOrBlank() || token.isNullOrBlank()) {
                        result.success(mapOf("ok" to false, "error" to "missing_credentials"))
                    } else {
                        BackgroundSyncStore.save(this, serverUrl, token)
                        BackgroundSyncScheduler.schedule(this)
                        result.success(mapOf("ok" to true, "intervalMinutes" to 15))
                    }
                }
                "clearBackgroundSync" -> {
                    BackgroundSyncStore.clear(this)
                    BackgroundSyncScheduler.cancel(this)
                    result.success(mapOf("ok" to true))
                }
                "refreshWidget" -> result.success(mapOf("ok" to false, "native" to true, "state" to "unavailable", "note" to "Flutter host 当前未注册 Today Widget provider"))
                "getWristbandCapabilities" -> result.success(jsonMap(wristband.capabilities()))
                "getWristbandStatus" -> result.success(jsonMap(wristband.status()))
                "connectWristband", "disconnectWristband", "openWristbandApp", "syncWristband" -> {
                    val operation = when (call.method) {
                        "connectWristband" -> "connect"
                        "disconnectWristband" -> "disconnect"
                        "openWristbandApp" -> "openApp"
                        else -> "sync"
                    }
                    val arguments = call.arguments as? Map<*, *>
                    wristbandExecutor.execute {
                        val value = try {
                            when (call.method) {
                                "connectWristband" -> wristband.connect(jsonObject(arguments))
                                "disconnectWristband" -> wristband.disconnect()
                                "openWristbandApp" -> wristband.openApp(jsonObject(arguments))
                                else -> wristband.sync(jsonObject(arguments))
                            }
                        } catch (_: Exception) {
                            JSONObject().put("ok", false).put("state", "error").put("error", "native_wristband_error")
                        }
                        result.success(jsonMap(value).plus("operation" to operation))
                    }
                }
                "pollWristbandEvents" -> result.success(jsonValue(wristband.drainEvents()))
                "pendingWristbandEvents" -> result.success(jsonValue(wristband.pendingEvents()))
                "acknowledgeWristbandEvents" -> {
                    val count = (call.arguments as? Number)?.toInt() ?: 0
                    wristband.acknowledgeEvents(count)
                    result.success(mapOf("ok" to true))
                }
=======
                "refreshWidget" -> result.success(mapOf("ok" to false, "native" to true, "state" to "unavailable", "note" to "Flutter host 当前未注册 Today Widget provider"))
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
                else -> result.notImplemented()
            }
        }
    }

<<<<<<< HEAD
    private fun capabilities(): Map<String, Any?> {
=======
    private fun capabilities(): Map<String, Any> {
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
        val manufacturer = Build.MANUFACTURER ?: "unknown"
        val xiaomi = manufacturer.lowercase().contains("xiaomi") || manufacturer.lowercase().contains("redmi")
        val notificationReady = Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "manufacturer" to manufacturer,
            "model" to Build.MODEL,
            "androidApi" to Build.VERSION.SDK_INT,
            "hyperOsCandidate" to xiaomi,
            "superIsland" to false,
            "superIslandState" to "unavailable",
            "superIslandNote" to "未接入可验证的公开超级岛 API",
            "islandAdapter" to "android.notification",
            "notificationFallback" to if (notificationReady) "available" else "permission_required",
            "notifications" to notificationReady,
            "exactAlarm" to (Build.VERSION.SDK_INT < 31 || (getSystemService(Context.ALARM_SERVICE) as? AlarmManager)?.canScheduleExactAlarms() == true),
            "eventSchema" to "fangcun.native.v1",
            "methodChannelReady" to true,
            "wristband" to wristbandCapabilities(),
        )
    }

<<<<<<< HEAD
    private fun wristbandCapabilities(): Map<String, Any?> = jsonMap(wristband.capabilities())

    private fun jsonObject(arguments: Map<*, *>?): JSONObject {
        val values = linkedMapOf<String, Any?>()
        arguments?.forEach { (key, value) -> values[key.toString()] = value }
        return JSONObject(values)
    }

    private fun jsonMap(value: JSONObject): Map<String, Any?> {
        val output = linkedMapOf<String, Any?>()
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            output[key] = jsonValue(value.opt(key))
        }
        return output
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.opt(it)) }
        // JSONObject can contain Java arrays (for example the wearable
        // permission list). Flutter's codec only accepts List, not String[].
        is Array<*> -> value.map(::jsonValue)
        else -> value
    }
=======
    private fun wristbandCapabilities(): Map<String, Any> = mapOf(
        "api" to "fangcun.wristband.v1",
        "available" to false,
        "state" to "unsupported",
        "adapter" to "none",
        "transport" to "bluetooth-le",
        "note" to "尚未接入手环厂商 SDK；当前仅提供稳定连接协议",
        "features" to mapOf("heartRate" to false, "steps" to false, "notifications" to false, "workout" to false),
        "requiresPermissions" to listOf("android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT"),
    )

    private fun wristbandUnavailable(operation: String): Map<String, Any> = mapOf(
        "ok" to false,
        "operation" to operation,
        "state" to "unsupported",
        "error" to "unsupported",
    ) + wristbandCapabilities()
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

    private fun saveSnapshot(event: String, payload: Map<String, Any?>) {
        val text = payload.entries.joinToString(",") { "\"${it.key}\":\"${it.value.toString().replace("\"", "\\\"")}\"" }
        getSharedPreferences(snapshotPrefs, MODE_PRIVATE).edit().putString("snapshot_v1", "{\"version\":1,\"lastEvent\":\"$event\",\"payload\":{$text},\"updatedAt\":${System.currentTimeMillis()}}").apply()
    }

    private fun readSnapshot(): Map<String, Any> = mapOf("raw" to (getSharedPreferences(snapshotPrefs, MODE_PRIVATE).getString("snapshot_v1", "{}") ?: "{}"))

    private fun saveTodaySnapshot(today: Map<String, Any?>) {
        val normalized = JSONObject()
        normalized.put("focus", today["focus"] ?: emptyList<Any>())
        normalized.put("nextEvent", today["nextEvent"] ?: JSONObject())
        normalized.put("deadlines", today["deadlines"] ?: emptyList<Any>())
        normalized.put("progress", ((today["progress"] as? Number)?.toDouble() ?: 0.0).coerceIn(0.0, 1.0))
        val current = getSharedPreferences(snapshotPrefs, MODE_PRIVATE).getString("snapshot_v1", "{}") ?: "{}"
        val snapshot = try { JSONObject(current) } catch (_: Exception) { JSONObject() }
        snapshot.put("version", 1).put("today", normalized).put("updatedAt", System.currentTimeMillis())
        getSharedPreferences(snapshotPrefs, MODE_PRIVATE).edit().putString("snapshot_v1", snapshot.toString()).apply()
    }

    private fun showNotification(event: String, payload: Map<String, Any?>): Map<String, Any> {
        val unavailable = mapOf("id" to "android.notification", "state" to "unavailable", "isSuperIsland" to false)
        if (notifications == null) return unavailable
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            return mapOf("id" to "android.notification", "state" to "permission_required", "isSuperIsland" to false)
        }
        val title = when (event) {
            "focus.start" -> "方寸 · Focus 进行中"
            "focus.pause" -> "方寸 · Focus 已暂停"
            "focus.complete" -> "方寸 · Focus 完成"
            "course.start" -> "方寸 · 日程进行中"
            "ddl.remind" -> "方寸 · 截止提醒"
            else -> "方寸 · 开发者事件"
        }
        val body = when (event) {
            "focus.start", "focus.pause", "focus.complete" -> "${payload["title"] ?: "C++训练"} · ${payload["progress"] ?: "43 / 60 min"}"
            "course.start" -> "${payload["title"] ?: "大学物理实验"} · ${payload["time"] ?: "14:30 - 16:30"}"
            "ddl.remind" -> "${payload["title"] ?: "实验报告"} · ${payload["due"] ?: "今天 23:59"}"
            else -> "已触发原生适配层事件"
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, notificationChannel) else Notification.Builder(this)
        builder.setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_EVENT)
            .setPriority(Notification.PRIORITY_HIGH)
            .setOnlyAlertOnce(true)
            .setOngoing(event == "focus.start" || event == "focus.pause" || event == "course.start")
            .setShowWhen(false)
        return try {
            notifications.notify(notificationId, builder.build())
            mapOf("id" to "android.notification", "state" to "delivered", "isSuperIsland" to false)
        } catch (_: SecurityException) {
            mapOf("id" to "android.notification", "state" to "permission_required", "isSuperIsland" to false)
        }
    }

    private fun playHaptic(semantic: String) {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        if (!vibrator.hasVibrator()) return
        val pattern = when (semantic) {
            "success" -> longArrayOf(0, 28, 44, 52)
            "confirm" -> longArrayOf(0, 24)
            "error" -> longArrayOf(0, 70, 40, 70)
            "snap" -> longArrayOf(0, 16)
            "start" -> longArrayOf(0, 20, 30, 36)
            else -> longArrayOf(0, 12)
        }
        if (Build.VERSION.SDK_INT >= 26) vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1)) else vibrator.vibrate(pattern, -1)
    }

    private fun hapticFor(event: String): String = when {
        event.endsWith(".complete") -> "success"
        event.endsWith(".start") -> "start"
        event.endsWith(".pause") -> "snap"
        event.endsWith(".remind") -> "confirm"
        else -> "light"
    }
<<<<<<< HEAD

    override fun onDestroy() {
        wristbandExecutor.shutdownNow()
        super.onDestroy()
    }
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
}
