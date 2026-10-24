package top.jxcz.orialis

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.media.projection.MediaProjectionManager
import android.media.projection.MediaProjectionConfig
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.widget.Toast

/** Uses explicitly enabled auxiliary capture, or a fresh Android consent session. */
class MemoryCaptureActivity : Activity() {
    private var requestedScope: String? = null
    private var waitingForCapture = false
    private val handler = Handler(Looper.getMainLooper())
    private val captureTimeout = Runnable {
        waitingForCapture = false
        stopService(Intent(this, MemoryProjectionService::class.java))
        Toast.makeText(this, "截屏未完成，请重新点击快捷开关", Toast.LENGTH_LONG).show()
        finish()
    }
    private val captureResult = object : ResultReceiver(handler) {
        override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
            waitingForCapture = false
            handler.removeCallbacks(captureTimeout)
            if (isFinishing || isDestroyed) return
            if (resultCode == RESULT_OK && requestedScope == MemoryStore.scope(this@MemoryCaptureActivity)) {
                Toast.makeText(this@MemoryCaptureActivity, "已存入 Orialis 记忆", Toast.LENGTH_SHORT).show()
            } else Toast.makeText(this@MemoryCaptureActivity, resultData?.getString("error") ?: "本次截屏未完成", Toast.LENGTH_LONG).show()
            finish()
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState?.getBoolean("capturing") == true) {
            stopService(Intent(this, MemoryProjectionService::class.java))
            Toast.makeText(this, "上次截屏已中断，请重新点击快捷开关", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        if (MemoryProjectionService.capturing || MemoryAccessibilityService.capturing) {
            Toast.makeText(this, "正在记录，请稍候", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        requestedScope = savedInstanceState?.getString("scope") ?: MemoryStore.scope(this)
        if (requestedScope == null) {
            Toast.makeText(this, "请先登录 Orialis 并打开一次记忆页面", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        if (savedInstanceState == null && MemoryAccessibilityService.capture(requestedScope!!)) {
            finish()
            return
        }
        if (savedInstanceState == null) {
            try {
                val manager = getSystemService(MediaProjectionManager::class.java)
                val consent = if (Build.VERSION.SDK_INT >= 34)
                    manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
                else manager.createScreenCaptureIntent()
                startActivityForResult(consent, 41)
            }
            catch (_: Exception) { Toast.makeText(this, "无法请求系统截屏授权", Toast.LENGTH_LONG).show(); finish() }
        }
    }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("scope", requestedScope)
        outState.putBoolean("capturing", waitingForCapture)
        super.onSaveInstanceState(outState)
    }
    @Deprecated("Android activity result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 41) return
        if (resultCode == RESULT_OK && data != null && requestedScope == MemoryStore.scope(this)) {
            try {
                val service = Intent(this, MemoryProjectionService::class.java).putExtra("resultCode", resultCode)
                    .putExtra("resultData", data).putExtra("scope", requestedScope).putExtra("resultReceiver", captureResult)
                waitingForCapture = true
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                // Keep the consent owner alive until this one-shot projection finishes.
                handler.postDelayed(captureTimeout, 12000)
                return
            } catch (_: Exception) { waitingForCapture = false; Toast.makeText(this, "无法启动本次截屏，请重新尝试", Toast.LENGTH_LONG).show() }
        } else Toast.makeText(this, "已取消本次屏幕记忆", Toast.LENGTH_SHORT).show()
        finish()
    }
    override fun onDestroy() {
        handler.removeCallbacks(captureTimeout)
        if (waitingForCapture) stopService(Intent(this, MemoryProjectionService::class.java))
        super.onDestroy()
    }
}
