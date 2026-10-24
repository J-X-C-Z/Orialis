package top.jxcz.orialis

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

internal class MemoryBridge(private val activity: MainActivity, messenger: BinaryMessenger) {
    companion object {
        const val ROUTE_EXTRA = "orialis.memory.open"
        private var active: MemoryBridge? = null
        fun notifyChanged(id: String? = null) {
            active?.let { bridge -> bridge.activity.runOnUiThread {
                if (!bridge.disposed) bridge.channel.invokeMethod("memoryChanged", mapOf("id" to id))
            } }
        }
    }
    private val channel = MethodChannel(messenger, "top.jxcz.orialis/memory")
    private val worker = Executors.newSingleThreadExecutor()
    private var disposed = false
    private var pendingRoute = activity.intent.getBooleanExtra(ROUTE_EXTRA, false)
    init {
        active = this
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(mapOf("supported" to (Build.VERSION.SDK_INT >= 21)))
                    "requestAddTile" -> {
                        if (Build.VERSION.SDK_INT >= 33) activity.getSystemService(StatusBarManager::class.java)
                            .requestAddTileService(ComponentName(activity, MemoryTileService::class.java), "记住屏幕",
                                Icon.createWithResource(activity, R.drawable.ic_memory), activity.mainExecutor) { code ->
                                    if (!disposed) result.success(code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                                        code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED)
                                }
                        else result.success(false)
                    }
                    "setScope" -> {
                        MemoryStore.setScope(activity, call.argument<String>("scope"))
                        result.success(null)
                    }
                    "takePendingRoute" -> {
                        result.success(if (pendingRoute) "/memory" else null)
                        pendingRoute = false
                        activity.intent.removeExtra(ROUTE_EXTRA)
                    }
                    "capture" -> {
                        check(MemoryStore.scope(activity) != null) { "请先登录并打开记忆页面" }
                        activity.startActivity(Intent(activity, MemoryCaptureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    "list", "read", "update", "delete", "prepareUpload" -> {
                        val expectedScope = MemoryStore.scope(activity)
                        worker.execute {
                            try {
                                val response = synchronized(MemoryStore) {
                                    check(MemoryStore.scope(activity) == expectedScope) { "账号已变更，请重试" }
                                    when (call.method) {
                                        "list" -> MemoryStore.list(activity).map(MemoryStore::asMap)
                                        "read" -> MemoryStore.read(activity, call.argument<String>("id") ?: "")?.let(MemoryStore::asMap)
                                        "update" -> MemoryStore.asMap(MemoryStore.update(activity, call.argument<String>("id") ?: "",
                                            call.argument<Map<String, Any?>>("fields") ?: emptyMap<String, Any?>()))
                                        "prepareUpload" -> MemoryStore.prepareUpload(activity, call.argument<String>("id") ?: "")
                                        else -> MemoryStore.delete(activity, call.argument<String>("id") ?: "")
                                    }
                                }
                                activity.runOnUiThread {
                                    if (!disposed) {
                                        if (MemoryStore.scope(activity) == expectedScope) result.success(response)
                                        else result.error("memory_scope_changed", "账号已变更，请重试", null)
                                    }
                                }
                            } catch (error: Exception) { activity.runOnUiThread {
                                if (!disposed) result.error("memory_store_error", error.message, null)
                            } }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("memory_error", error.message, null) }
        }
    }
    fun onNewIntent(intent: Intent) {
        if (intent.getBooleanExtra(ROUTE_EXTRA, false)) {
            pendingRoute = true
            channel.invokeMethod("memoryRoute", "/memory")
        }
    }
    fun dispose() { disposed = true; channel.setMethodCallHandler(null); worker.shutdown(); if (active === this) active = null }
}
