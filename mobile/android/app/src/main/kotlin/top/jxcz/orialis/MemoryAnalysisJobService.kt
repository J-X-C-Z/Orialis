package top.jxcz.orialis

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Runs the existing memory analyzer without opening an Activity or copying its login token. */
class MemoryAnalysisJobService : JobService() {
    companion object {
        private const val JOB_ID = 0x4f524d
        private var active: MemoryAnalysisJobService? = null
        fun schedule(context: Context) {
            val app = context.applicationContext
            Handler(Looper.getMainLooper()).post {
                if (active != null || MemoryStore.scope(app) == null) return@post
                try {
                    (app.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).schedule(
                        JobInfo.Builder(JOB_ID, ComponentName(app, MemoryAnalysisJobService::class.java))
                            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                            .setMinimumLatency(1)
                            .setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
                            .build(),
                    )
                } catch (_: RuntimeException) { /* The saved inbox is still available on the next app launch. */ }
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var store: MemoryBackgroundStoreBridge? = null
    private var control: MethodChannel? = null
    private var parameters: JobParameters? = null
    private var expectedScope: String? = null
    private val timeout = Runnable { finish(retry = true) }

    override fun onStartJob(params: JobParameters): Boolean {
        expectedScope = MemoryStore.scope(this) ?: return false
        parameters = params
        active = this
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val backgroundEngine = FlutterEngine(applicationContext)
            engine = backgroundEngine
            store = MemoryBackgroundStoreBridge(this, expectedScope!!, backgroundEngine.dartExecutor.binaryMessenger)
            control = MethodChannel(backgroundEngine.dartExecutor.binaryMessenger, "top.jxcz.orialis/memoryBackground").also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "isCurrent") {
                        result.success(MemoryStore.scope(this) == expectedScope)
                    } else if (call.method == "complete") {
                        result.success(null)
                        main.post { finish(call.argument<Boolean>("retry") == true, call.argument<Boolean>("completed") == true) }
                    } else result.notImplemented()
                }
            }
            main.postDelayed(timeout, 350_000)
            backgroundEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "memoryBackgroundMain"),
            )
            return true
        } catch (_: Exception) {
            main.post { finish(retry = pending()) }
            return true
        }
    }

    private fun pending(): Boolean = try {
        MemoryStore.list(this).any { it.optString("analysisStatus") in setOf("pending", "analyzing") ||
            it.optString("analysisStatus") == "completed" && it.optString("category") !in setOf("ai", "other") }
    } catch (_: Exception) { false }

    private fun finish(retry: Boolean, completed: Boolean = false) {
        val params = parameters ?: return
        val changedAccount = MemoryStore.scope(this) != expectedScope
        val reschedule = retry || (completed || changedAccount) && pending()
        close()
        jobFinished(params, reschedule)
    }

    private fun close() {
        main.removeCallbacks(timeout)
        parameters = null
        control?.setMethodCallHandler(null)
        control = null
        store?.dispose()
        store = null
        engine?.destroy()
        engine = null
        if (active === this) active = null
    }

    override fun onStopJob(params: JobParameters): Boolean {
        val reschedule = pending()
        close()
        return reschedule
    }

    override fun onDestroy() { close(); super.onDestroy() }
}

/** A background isolate may use its account's inbox, but cannot switch the app's account. */
private class MemoryBackgroundStoreBridge(context: Context, private val scope: String, messenger: io.flutter.plugin.common.BinaryMessenger) {
    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, "top.jxcz.orialis/memory")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "takePendingRoute") { result.success(null); return@setMethodCallHandler }
            worker.execute {
                try {
                    val response = synchronized(MemoryStore) {
                        check(MemoryStore.scope(app) == scope) { "账号已变更，请重试" }
                        when (call.method) {
                            "status" -> mapOf("supported" to true)
                            "setScope" -> { check(call.argument<String>("scope") == scope) { "后台账号已失效" }; null }
                            "list" -> MemoryStore.list(app).map(MemoryStore::asMap)
                            "read" -> MemoryStore.read(app, call.argument<String>("id") ?: "")?.let(MemoryStore::asMap)
                            "update" -> MemoryStore.asMap(MemoryStore.update(app, call.argument<String>("id") ?: "",
                                call.argument<Map<String, Any?>>("fields") ?: emptyMap<String, Any?>(),
                                call.argument<String>("expectedAnalysisRequestId")))
                            "prepareUpload" -> MemoryStore.prepareUpload(app, call.argument<String>("id") ?: "")
                            else -> error("后台记忆不支持此操作")
                        }
                    }
                    main.post {
                        if (!disposed) {
                            if (MemoryStore.scope(app) == scope) {
                                result.success(response)
                                if (call.method == "update") MemoryBridge.notifyChanged(call.argument<String>("id"))
                            }
                            else result.error("memory_scope_changed", "账号已变更，请重试", null)
                        }
                    }
                } catch (_: Exception) {
                    main.post { if (!disposed) result.error("memory_scope_changed", "后台记忆账号或记录已失效", null) }
                }
            }
        }
    }

    fun dispose() { disposed = true; channel.setMethodCallHandler(null); worker.shutdownNow() }
}
