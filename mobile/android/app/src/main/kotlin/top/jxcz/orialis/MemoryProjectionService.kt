package top.jxcz.orialis

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.ResultReceiver
import android.util.DisplayMetrics
import android.view.WindowManager
import android.widget.Toast

/** One consent token, one virtual display, one saved screenshot; never reads app nodes. */
class MemoryProjectionService : Service() {
    companion object { @Volatile var capturing = false; private set }
    private val thread = HandlerThread("orialis-screen-memory")
    private lateinit var handler: Handler
    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var finished = false
    private var started = false
    private var captureScope: String? = null
    private var resultReceiver: ResultReceiver? = null
    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() { finishCapture(null, "系统已停止本次截屏") }
    }
    private val timeout = Runnable { finishCapture(null, "截屏超时，请重新点击快捷开关") }
    override fun onCreate() { super.onCreate(); capturing = true; thread.start(); handler = Handler(thread.looper) }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (started) {
            Toast.makeText(this, "正在记录，请稍候", Toast.LENGTH_SHORT).show()
            return START_NOT_STICKY
        }
        started = true
        @Suppress("DEPRECATION")
        resultReceiver = intent?.getParcelableExtra<ResultReceiver>("resultReceiver")
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel("screen_memory_capture", "屏幕记忆截屏", NotificationManager.IMPORTANCE_LOW))
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "screen_memory_capture") else Notification.Builder(this)
            val notice = builder.setSmallIcon(R.drawable.ic_memory).setContentTitle("正在记录这一次屏幕")
                .setContentText("截屏保存后立即停止").setOngoing(true).setVisibility(Notification.VISIBILITY_PRIVATE).build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(4102, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            else startForeground(4102, notice)
            val scope = intent?.getStringExtra("scope")
            @Suppress("DEPRECATION") val data = intent?.getParcelableExtra<Intent>("resultData")
            val resultCode = intent?.getIntExtra("resultCode", Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
            captureScope = scope
            if (scope == null || data == null || scope != MemoryStore.scope(this) || resultCode != Activity.RESULT_OK) {
                handler.post { finishCapture(null, "本次截屏授权已失效，请重试") }
            } else {
                // Wait until the consent panel has left; the capture Activity itself stays transparent.
                handler.postDelayed({ beginCapture(scope, resultCode, data) }, 650)
            }
        } catch (_: Exception) { handler.post { finishCapture(null, "系统未允许本次截屏，请重新授权") } }
        return START_NOT_STICKY
    }
    private fun beginCapture(scope: String, resultCode: Int, data: Intent) {
        if (finished) return
        try {
            check(MemoryStore.scope(this) == scope) { "账号已变更，请重新记录" }
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION") getSystemService(WindowManager::class.java).defaultDisplay.getRealMetrics(metrics)
            val width = metrics.widthPixels
            val height = metrics.heightPixels
            val surfaceReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            reader = surfaceReader
            surfaceReader.setOnImageAvailableListener({ source ->
                val image = source.acquireLatestImage() ?: return@setOnImageAvailableListener
                if (finished) { image.close(); return@setOnImageAvailableListener }
                var bitmap: Bitmap? = null
                var padded: Bitmap? = null
                var imageFile: java.io.File? = null
                var savedId: String? = null
                var failure: String? = null
                try {
                    val plane = image.planes[0]
                    val paddedWidth = plane.rowStride / plane.pixelStride
                    padded = Bitmap.createBitmap(paddedWidth, image.height, Bitmap.Config.ARGB_8888)
                    padded.copyPixelsFromBuffer(plane.buffer)
                    bitmap = Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
                    // ImageReader can deliver a transparent/black startup frame before the display is composed.
                    if (!MemoryFrame.hasVisibleContent(bitmap.width, bitmap.height, bitmap::getPixel))
                        return@setOnImageAvailableListener
                    val id = MemoryStore.newId()
                    val file = MemoryStore.imageFile(this, scope, id)
                    imageFile = file
                    file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                    MemoryStore.save(this, scope, id, "", "屏幕截图", "", imagePath = file.absolutePath)
                    savedId = id
                } catch (error: Exception) {
                    imageFile?.delete()
                    failure = error.message ?: "截图保存失败"
                } finally {
                    image.close()
                    bitmap?.recycle()
                    if (padded !== bitmap) padded?.recycle()
                }
                finishCapture(savedId, failure)
            }, handler)
            projection = getSystemService(MediaProjectionManager::class.java).getMediaProjection(resultCode, data)
            projection!!.registerCallback(projectionCallback, handler)
            display = projection!!.createVirtualDisplay("Orialis single screenshot", width, height, metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surfaceReader.surface, null, handler)
            handler.postDelayed(timeout, 10000)
        } catch (error: Exception) { finishCapture(null, error.message ?: "系统截屏失败") }
    }
    private fun finishCapture(id: String?, error: String?) {
        if (finished) return
        finished = true
        release()
        main.post {
            try {
                if (id != null && MemoryStore.scope(this) == captureScope) {
                    MemoryBridge.notifyChanged(id)
                    resultReceiver?.send(Activity.RESULT_OK, Bundle().apply { putString("id", id) })
                } else {
                    val reason = error ?: "账号已变更，请重新记录"
                    resultReceiver?.send(Activity.RESULT_CANCELED, Bundle().apply { putString("error", reason) })
                    if (resultReceiver == null) Toast.makeText(this, reason, Toast.LENGTH_LONG).show()
                }
            } finally { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        }
    }
    private fun release() {
        handler.removeCallbacks(timeout)
        display?.release(); display = null
        reader?.setOnImageAvailableListener(null, null); reader?.close(); reader = null
        projection?.unregisterCallback(projectionCallback); projection?.stop(); projection = null
    }
    override fun onDestroy() {
        capturing = false
        handler.post { finished = true; release(); thread.quitSafely() }
        super.onDestroy()
    }
}
