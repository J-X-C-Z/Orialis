package top.jxcz.orialis

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Orialis-owned types. These are not Xiaomi API or package names. */
enum class WearAvailability(val wire: String) { AVAILABLE("available"), SDK_UNAVAILABLE("sdk_unavailable"), UNSUPPORTED("unsupported") }
enum class WearServiceState(val wire: String) { UNKNOWN("unknown"), OFFLINE("offline"), ONLINE("online") }
data class WearDiagnostics(
    val availability: WearAvailability,
    val serviceConnection: WearServiceState = WearServiceState.UNKNOWN,
    val nodeCount: Int? = null,
    val nodeIds: List<String> = emptyList(),
    val wearAppInstalled: Boolean? = null,
    val permissionsGranted: Boolean? = null,
    val session: String? = null,
    val observedNodeId: String? = null,
    val lastError: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "availability" to availability.wire, "serviceConnection" to serviceConnection.wire,
        "nodeCount" to nodeCount, "nodeIds" to nodeIds, "wearAppInstalled" to wearAppInstalled,
        "permissionsGranted" to permissionsGranted, "session" to session, "observedNodeId" to observedNodeId, "lastError" to lastError
    )
}
data class WearIncomingMessage(val nodeId: String, val session: String, val data: String)
data class WearFailure(val code: String, val message: String)

/** Every completion is asynchronous-capable. An authorized adapter owns native
 * sessions, listener teardown and rejection of callbacks from revoked sessions.
 * This seam deliberately declares no vendor library identity or permission.
 */
interface WearAdapter {
    fun connect(done: (WearDiagnostics) -> Unit)
    fun refresh(done: (WearDiagnostics) -> Unit)
    fun requestPermissions(done: (WearDiagnostics) -> Unit)
    fun selectNode(nodeId: String, done: (WearDiagnostics) -> Unit)
    fun openApp(done: (WearFailure?) -> Unit)
    fun disconnect(done: (WearFailure?) -> Unit)
    fun send(nodeId: String, session: String, data: String, done: (WearFailure?) -> Unit)
    fun observe(diagnostics: (WearDiagnostics) -> Unit, messages: (WearIncomingMessage) -> Unit)
    fun stopObserving()
    fun dispose()
}
class SdkUnavailableWearAdapter : WearAdapter {
    private fun status() = WearDiagnostics(WearAvailability.SDK_UNAVAILABLE, lastError = "sdk_unavailable")
    override fun connect(done: (WearDiagnostics) -> Unit) = done(status())
    override fun refresh(done: (WearDiagnostics) -> Unit) = done(status())
    override fun requestPermissions(done: (WearDiagnostics) -> Unit) = done(status())
    override fun selectNode(nodeId: String, done: (WearDiagnostics) -> Unit) = done(status())
    override fun disconnect(done: (WearFailure?) -> Unit) = done(null)
    override fun openApp(done: (WearFailure?) -> Unit) =
        done(WearFailure("sdk_unavailable", "Xiaomi Wear SDK is not available"))
    override fun send(nodeId: String, session: String, data: String, done: (WearFailure?) -> Unit) =
        done(WearFailure("sdk_unavailable", "Authorized Xiaomi Wear SDK is not installed"))
    override fun observe(diagnostics: (WearDiagnostics) -> Unit, messages: (WearIncomingMessage) -> Unit) = diagnostics(status())
    override fun stopObserving() {}
    override fun dispose() {}
}

class WearBridge(messenger: BinaryMessenger, private val adapter: WearAdapter = SdkUnavailableWearAdapter()) {
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "top.jxcz.orialis/wear")
    private val events = EventChannel(messenger, "top.jxcz.orialis/wear/events")
    private var disposed = false
    private var observerGeneration = 0
    private fun deliver(action: () -> Unit) { main.post { if (!disposed) action() } }
    init {
        methods.setMethodCallHandler { call, result ->
            val status: (WearDiagnostics) -> Unit = { value -> deliver { result.success(value.toMap()) } }
            val completed: (WearFailure?) -> Unit = { failure -> deliver {
                if (failure == null) result.success(null) else result.error(failure.code, failure.message, null)
            } }
            when (call.method) {
                "connect" -> adapter.connect(status)
                "refresh" -> adapter.refresh(status)
                "requestPermissions" -> adapter.requestPermissions(status)
                "selectNode" -> {
                    val node = call.argument<String>("nodeId")
                    if (node.isNullOrEmpty()) result.error("invalid_node", "Missing selected node", null)
                    else adapter.selectNode(node, status)
                }
                "disconnect" -> adapter.disconnect(completed)
                "openApp" -> adapter.openApp(completed)
                "send" -> {
                    val node = call.argument<String>("nodeId")
                    val session = call.argument<String>("session")
                    val data = call.argument<String>("data")
                    if (node.isNullOrEmpty() || session.isNullOrEmpty() || data == null || data.toByteArray(Charsets.UTF_8).size > 16384) {
                        result.error("invalid_message", "Missing identity or frame exceeds UTF-8 byte limit", null)
                    } else adapter.send(node, session, data, completed)
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                val generation = ++observerGeneration
                adapter.observe(
                    { value -> deliver { if (generation == observerGeneration) sink.success(mapOf("type" to "diagnostics", "value" to value.toMap())) } },
                    { value -> deliver { if (generation == observerGeneration) sink.success(mapOf("type" to "message", "nodeId" to value.nodeId, "session" to value.session, "data" to value.data)) } }
                )
            }
            override fun onCancel(arguments: Any?) { ++observerGeneration; adapter.stopObserving() }
        })
    }
    fun dispose() {
        disposed = true
        ++observerGeneration
        adapter.stopObserving()
        adapter.dispose()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
