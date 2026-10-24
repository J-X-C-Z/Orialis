package top.jxcz.orialis

import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

internal class ChatShareBridge(private val activity: MainActivity, messenger: BinaryMessenger) {
    companion object { const val ID_EXTRA = "orialis.chatShare.id" }
    private val channel = MethodChannel(messenger, "top.jxcz.orialis/chat_share")
    private val worker = Executors.newSingleThreadExecutor()
    private var disposed = false
    private var preferredId = activity.intent.getStringExtra(ID_EXTRA)
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("pending", "read", "complete")) { result.notImplemented(); return@setMethodCallHandler }
            val expectedScope = MemoryStore.scope(activity)
            val requestedId = if (call.method == "pending") preferredId else call.argument<String>("id")
            worker.execute {
                try {
                    val response = synchronized(MemoryStore) {
                        check(MemoryStore.scope(activity) == expectedScope) { "账号已变更，请重新分享" }
                        when (call.method) {
                            "pending" -> ChatShareStore.pending(activity, requestedId)
                            "read" -> ChatShareStore.read(activity, requestedId ?: "")
                            else -> { ChatShareStore.complete(activity, requestedId ?: ""); null }
                        }
                    }
                    activity.runOnUiThread {
                        if (!disposed) {
                            if (MemoryStore.scope(activity) == expectedScope) {
                                if (call.method == "complete" && preferredId == requestedId) {
                                    preferredId = null
                                    activity.intent.removeExtra(ID_EXTRA)
                                }
                                result.success(response)
                            } else result.error("chat_share_scope_changed", "账号已变更，请重新分享", null)
                        }
                    }
                } catch (error: Exception) { activity.runOnUiThread {
                    if (!disposed) result.error("chat_share_error", error.message, null)
                } }
            }
        }
    }
    fun onNewIntent(intent: Intent) {
        intent.getStringExtra(ID_EXTRA)?.let { id ->
            preferredId = id
            channel.invokeMethod("shareReceived", id)
        }
    }
    fun dispose() { disposed = true; channel.setMethodCallHandler(null); worker.shutdown() }
}
