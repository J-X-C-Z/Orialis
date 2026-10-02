package top.jxcz.orialis

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.xiaomi.xms.wearable.Wearable
import com.xiaomi.xms.wearable.auth.Permission
import com.xiaomi.xms.wearable.message.OnMessageReceivedListener
import com.xiaomi.xms.wearable.node.DataItem
import com.xiaomi.xms.wearable.node.DataSubscribeResult
import com.xiaomi.xms.wearable.node.OnDataChangedListener
import com.xiaomi.xms.wearable.service.OnServiceConnectionListener
import com.xiaomi.xms.wearable.tasks.Task
import java.util.UUID
import java.util.concurrent.Executor

/** All mutable state and vendor completions are serialized on main. No SDK Task
 * is synchronously awaited. Native session IDs are transport lifetimes, never
 * account credentials; Flutter owns account verification and application ACKs.
 */
class XiaomiWearAdapter(context: Context) : WearAdapter {
    private val main = Handler(Looper.getMainLooper())
    private val callbackExecutor = Executor { command -> main.post(command) }
    private val appContext = context.applicationContext
    private val nodesApi = Wearable.getNodeApi(appContext)
    private val authApi = Wearable.getAuthApi(appContext)
    private val messagesApi = Wearable.getMessageApi(appContext)
    private val serviceApi = Wearable.getServiceApi(appContext)
    private var disposed = false
    private var enabled = false
    private var generation = 0L
    private var operation = 0L
    private var service = WearServiceState.UNKNOWN
    private var nodes: List<String> = emptyList()
    private var nodeCount: Int? = null
    private var selected: String? = null
    private var installed: Boolean? = null
    private var permitted: Boolean? = null
    private var session: String? = null
    private var error: String? = null
    private var registeredNode: String? = null
    private var statusObserver: ((WearDiagnostics) -> Unit)? = null
    private var messageObserver: ((WearIncomingMessage) -> Unit)? = null
    private var pendingStatus: ((WearDiagnostics) -> Unit)? = null
    private var statusTimeout: Runnable? = null
    private var cleanupCount = 0
    private val afterCleanup = mutableListOf<Pair<Long, () -> Unit>>()
    private data class PendingCall(val done: (WearFailure?) -> Unit, val timeout: Runnable)
    private val pendingCalls = mutableMapOf<String, PendingCall>()

    private val serviceListener = object : OnServiceConnectionListener {
        override fun onServiceConnected() = onMain {
            if (disposed) return@onMain
            service = WearServiceState.ONLINE
            if (enabled) publish()
        }
        override fun onServiceDisconnected() = onMain {
            if (disposed) return@onMain
            service = WearServiceState.OFFLINE
            if (enabled) {
                revoke("wearable_service_disconnected")
                nodes = emptyList()
                nodeCount = null
                installed = null
                permitted = null
                error = "wearable_service_disconnected"
                finishStatus()
            }
        }
    }

    init { serviceApi.registerServiceConnectionListener(serviceListener) }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post { action() }
    }

    private fun snapshot() = WearDiagnostics(
        availability = WearAvailability.AVAILABLE,
        serviceConnection = service,
        nodeCount = nodeCount,
        nodeIds = nodes,
        wearAppInstalled = installed,
        permissionsGranted = permitted,
        session = session,
        observedNodeId = selected,
        lastError = error
    )

    private fun publish() { if (!disposed) statusObserver?.invoke(snapshot()) }
    private fun current(op: Long) = !disposed && enabled && operation == op && pendingStatus != null

    private fun begin(done: (WearDiagnostics) -> Unit, timeoutMs: Long = 8000L): Long {
        val previous = pendingStatus
        pendingStatus = null
        statusTimeout?.let(main::removeCallbacks)
        if (previous != null && session == null && registeredNode != null) revoke("operation_cancelled")
        previous?.invoke(snapshot())
        operation++
        enabled = true
        pendingStatus = done
        error = null
        val op = operation
        statusTimeout = Runnable {
            if (current(op)) {
                revoke("connection_timeout")
                error = "connection_timeout"
                finishStatus()
            }
        }.also { main.postDelayed(it, timeoutMs) }
        return op
    }

    private fun finishStatus() {
        statusTimeout?.let(main::removeCallbacks)
        statusTimeout = null
        val callback = pendingStatus
        pendingStatus = null
        publish()
        callback?.invoke(snapshot())
    }

    private fun fail(op: Long, code: String) {
        if (!current(op)) return
        revoke(code)
        error = code
        finishStatus()
    }

    private fun <T> query(
        op: Long,
        code: String,
        makeTask: () -> Task<T>,
        success: (T) -> Unit,
        failure: (Exception) -> Unit = { fail(op, code) }
    ) {
        if (!current(op)) return
        try {
            makeTask()
                .addOnSuccessListener(callbackExecutor) { value -> if (current(op)) success(value) }
                .addOnFailureListener(callbackExecutor) { exception ->
                    if (current(op)) { logFailure(code, exception); failure(exception) }
                }
        } catch (exception: Exception) {
            if (current(op)) { logFailure(code, exception); failure(exception) }
        }
    }

    private fun logFailure(code: String, exception: Exception) {
        // Vendor messages/stack traces may include device IDs or app payloads.
        // Log only our fixed operation code and exception class names.
        val classes = mutableListOf<String>()
        var cause: Throwable? = exception
        while (cause != null && classes.size < 5) {
            classes.add(cause.javaClass.name)
            val next = cause.cause
            if (next === cause) break
            cause = next
        }
        Log.w("OrialisWear", "$code: ${classes.joinToString(" -> ")}")
    }

    override fun connect(done: (WearDiagnostics) -> Unit) = refresh(done)

    override fun refresh(done: (WearDiagnostics) -> Unit) = onMain {
        if (disposed) { done(snapshot()); return@onMain }
        val op = begin(done)
        awaitService(op, 0)
    }

    private fun awaitService(op: Long, attempt: Int) {
        query(op, "wearable_service_unavailable", { serviceApi.getServiceApiLevel() }, {
            service = WearServiceState.ONLINE
            discover(op, 0)
        }, {
            if (attempt < 3) {
                main.postDelayed({ if (current(op)) awaitService(op, attempt + 1) }, 500L)
                return@query
            }
            service = WearServiceState.OFFLINE
            nodes = emptyList()
            nodeCount = null
            installed = null
            permitted = null
            fail(op, "wearable_service_unavailable")
        })
    }

    private fun discover(op: Long, attempt: Int) {
        query(op, "node_discovery_failed", { nodesApi.getConnectedNodes() }, { found ->
            nodes = found.map { it.id }.filter { it.isNotEmpty() }.distinct()
            nodeCount = nodes.size
            if (nodes.isEmpty() && attempt < 3) {
                main.postDelayed({ if (current(op)) discover(op, attempt + 1) }, 500L)
                return@query
            }
            val node = selected
            if (node != null && !nodes.contains(node)) {
                revoke("selected_node_disconnected")
                selected = null
                installed = null
                permitted = null
                error = "selected_node_disconnected"
                finishStatus()
            } else if (node != null) {
                prepare(op, node, false)
            } else {
                error = if (nodes.isEmpty()) "no_connected_node" else null
                finishStatus()
            }
        })
    }

    override fun selectNode(nodeId: String, done: (WearDiagnostics) -> Unit) = onMain {
        if (disposed) { done(snapshot()); return@onMain }
        if (!nodes.contains(nodeId)) {
            done(snapshot().copy(lastError = "invalid_node"))
            return@onMain
        }
        val op = begin(done)
        if (selected != nodeId) {
            revoke("target_changed")
            selected = nodeId
            installed = null
            permitted = null
        }
        prepare(op, nodeId, false)
    }

    override fun requestPermissions(done: (WearDiagnostics) -> Unit) = onMain {
        if (disposed) { done(snapshot()); return@onMain }
        val node = selected
        if (node == null || !nodes.contains(node)) {
            done(snapshot().copy(lastError = "select_node_first"))
            return@onMain
        }
        val op = begin(done, timeoutMs = 60000L)
        prepare(op, node, true)
    }

    private fun prepare(op: Long, node: String, requestPermission: Boolean) {
        query(op, "wear_app_check_unavailable", { nodesApi.isWearAppInstalled(node) }, { value ->
            installed = value
            if (!value) fail(op, "wear_app_not_installed")
            else checkPermission(op, node, requestPermission)
        }, { exception ->
            // An unsupported query is not proof that the app is absent.
            var cause: Throwable? = exception
            var missing = false
            while (cause != null) {
                if (cause.javaClass.name == "com.xiaomi.xms.wearable.exception.AppNotInstalledException") missing = true
                val next = cause.cause
                if (next === cause) break
                cause = next
            }
            installed = if (missing) false else null
            if (missing) fail(op, "wear_app_not_installed")
            else {
                error = "wear_app_check_unavailable"
                checkPermission(op, node, requestPermission)
            }
        })
    }

    private fun checkPermission(op: Long, node: String, requestPermission: Boolean) {
        query(op, "permission_check_failed", { authApi.checkPermission(node, Permission.DEVICE_MANAGER) }, { granted ->
            permitted = granted
            if (granted) register(op, node)
            else if (requestPermission) requestDevicePermission(op, node)
            else fail(op, "permission_required")
        }, {
            permitted = null
            // A failed permission query is not an authorization denial. Only
            // an explicit user request may continue into the real SDK prompt.
            if (requestPermission) requestDevicePermission(op, node)
            else fail(op, "permission_check_failed")
        })
    }

    private fun requestDevicePermission(op: Long, node: String) {
        query(op, "permission_denied", { authApi.requestPermission(node, Permission.DEVICE_MANAGER) }, { permissions ->
            permitted = permissions.any { it == Permission.DEVICE_MANAGER }
            if (permitted == true) register(op, node) else fail(op, "permission_denied")
        })
    }

    private fun register(op: Long, node: String) {
        // A healthy refresh keeps the same session and in-flight ACK binding.
        if (session != null && registeredNode == node) { finishStatus(); return }
        if (cleanupCount != 0) {
            afterCleanup.add(op to { register(op, node) })
            return
        }
        val lifetime = generation
        registeredNode = node // Covers revocation while addListener is pending.
        val messageListener = OnMessageReceivedListener { source, bytes ->
            onMain {
                val activeSession = session
                if (!disposed && enabled && generation == lifetime && source == selected &&
                    source == node && activeSession != null && bytes.size <= MAX_FRAME_BYTES) {
                    messageObserver?.invoke(WearIncomingMessage(source, activeSession, bytes.toString(Charsets.UTF_8)))
                }
            }
        }
        val connectionListener = OnDataChangedListener { source, item, change ->
            onMain {
                if (!disposed && enabled && generation == lifetime && source == selected &&
                    item.type == DataItem.ITEM_CONNECTION.type &&
                    change.connectedStatus != DataSubscribeResult.RESULT_CONNECTION_CONNECTED) {
                    revoke("selected_node_disconnected")
                    nodes = nodes.filter { it != source }
                    nodeCount = nodes.size
                    installed = null
                    permitted = null
                    error = "selected_node_disconnected"
                    finishStatus()
                }
            }
        }
        query(op, "message_listener_failed", { messagesApi.addListener(node, messageListener) }, {
            query(op, "connection_subscription_failed", {
                nodesApi.subscribe(node, DataItem.ITEM_CONNECTION, connectionListener)
            }, subscribed@{
                if (generation != lifetime) { fail(op, "session_revoked"); return@subscribed }
                session = UUID.randomUUID().toString()
                finishStatus()
            })
        })
    }

    /** Remove before the next registration, since SDK removeListener is node-wide. */
    private fun cleanup(node: String) {
        cleanupCount += 2
        fun completed() {
            cleanupCount--
            if (cleanupCount == 0) {
                val ready = afterCleanup.toList()
                afterCleanup.clear()
                ready.forEach { (op, action) -> if (current(op)) action() }
            }
        }
        fun release(makeTask: () -> Task<Void>) {
            try {
                makeTask().addOnSuccessListener(callbackExecutor) { completed() }
                    .addOnFailureListener(callbackExecutor) { completed() }
            } catch (_: Exception) { completed() }
        }
        release { messagesApi.removeListener(node) }
        release { nodesApi.unsubscribe(node, DataItem.ITEM_CONNECTION) }
    }

    private fun revoke(reason: String) {
        generation++
        session = null
        val registered = registeredNode
        registeredNode = null
        afterCleanup.clear()
        if (registered != null) cleanup(registered)
        val calls = pendingCalls.values.toList()
        pendingCalls.clear()
        calls.forEach {
            main.removeCallbacks(it.timeout)
            it.done(WearFailure("session_revoked", reason))
        }
    }

    override fun disconnect(done: (WearFailure?) -> Unit) = onMain {
        enabled = false
        operation++
        revoke("session_revoked")
        nodes = emptyList()
        nodeCount = null
        selected = null
        installed = null
        permitted = null
        error = null
        finishStatus()
        done(null)
    }

    private fun transportCall(
        node: String,
        expectedSession: String,
        code: String,
        done: (WearFailure?) -> Unit,
        makeTask: () -> Task<Void>
    ) {
        if (disposed || !enabled || selected != node || session != expectedSession ||
            permitted != true || installed == false || service != WearServiceState.ONLINE) {
            done(WearFailure("session_revoked", "Selected wearable session is not active"))
            return
        }
        val lifetime = generation
        val id = UUID.randomUUID().toString()
        fun finish(failure: WearFailure?) {
            val call = pendingCalls.remove(id) ?: return
            main.removeCallbacks(call.timeout)
            call.done(if (generation == lifetime && session == expectedSession) failure
                else WearFailure("session_revoked", "Wearable session changed"))
        }
        val timeout = Runnable { finish(WearFailure(code, "Wearable operation timed out")) }
        pendingCalls[id] = PendingCall(done, timeout)
        main.postDelayed(timeout, 8000L)
        try {
            makeTask().addOnSuccessListener(callbackExecutor) { finish(null) }
                .addOnFailureListener(callbackExecutor) { finish(WearFailure(code, "Wearable operation failed")) }
        } catch (_: Exception) { finish(WearFailure(code, "Wearable operation failed")) }
    }

    override fun send(nodeId: String, session: String, data: String, done: (WearFailure?) -> Unit) = onMain {
        val bytes = data.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_FRAME_BYTES) {
            done(WearFailure("invalid_message", "Frame exceeds UTF-8 byte limit"))
            return@onMain
        }
        transportCall(nodeId, session, "message_send_failed", done) { messagesApi.sendMessage(nodeId, bytes) }
    }

    override fun openApp(done: (WearFailure?) -> Unit) = onMain {
        val node = selected
        val activeSession = session
        if (node == null || activeSession == null) {
            done(WearFailure("connection_not_ready", "Select and authorize a wearable first"))
            return@onMain
        }
        transportCall(node, activeSession, "launch_failed", done) { nodesApi.launchWearApp(node, "/pages/home") }
    }

    override fun observe(diagnostics: (WearDiagnostics) -> Unit, messages: (WearIncomingMessage) -> Unit) = onMain {
        if (disposed) return@onMain
        statusObserver = diagnostics
        messageObserver = messages
        publish()
    }

    override fun stopObserving() = onMain {
        statusObserver = null
        messageObserver = null
        if (!disposed) disconnect { }
    }

    override fun dispose() = onMain {
        if (disposed) return@onMain
        disconnect { }
        statusObserver = null
        messageObserver = null
        disposed = true
        serviceApi.unregisterServiceConnectionListener(serviceListener)
    }

    companion object {
        // Orialis protocol limit, not a claim about every Xiaomi firmware.
        private const val MAX_FRAME_BYTES = 16384
    }
}
