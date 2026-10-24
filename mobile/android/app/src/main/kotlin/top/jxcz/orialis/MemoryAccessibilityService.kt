package top.jxcz.orialis

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.Toast
import java.io.File
import java.util.concurrent.Executors

/** Reads one screen only after the user taps the memory shortcut. */
class MemoryAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile private var instance: MemoryAccessibilityService? = null
        @Volatile var capturing = false; private set
        fun available() = Build.VERSION.SDK_INT >= 30 && instance != null
        fun capture(scope: String): Boolean {
            val service = instance ?: return false
            if (Build.VERSION.SDK_INT < 30 || capturing) return false
            capturing = true
            // The transparent tile trampoline must close before reading the original app.
            service.main.postDelayed({ service.captureScreen(scope) }, 650)
            return true
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    override fun onServiceConnected() { super.onServiceConnected(); instance = this }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    private data class VisibleScreen(val sourcePackage: String = "", val sourceLabel: String = "屏幕截图", val text: String = "")

    private fun visibleScreen(): VisibleScreen {
        val roots = windows.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
            .sortedByDescending { if (it.isActive) 2 else if (it.isFocused) 1 else 0 }
            .mapNotNull { it.root }
        val root = (listOfNotNull(rootInActiveWindow) + roots).firstOrNull {
            val name = it.packageName?.toString().orEmpty()
            name.isNotEmpty() && name != packageName && name != "com.android.systemui"
        } ?: return VisibleScreen()
        val source = root.packageName?.toString().orEmpty()
        val label = try { packageManager.getApplicationLabel(packageManager.getApplicationInfo(source, 0)).toString() }
            catch (_: Exception) { source }
        val lines = linkedSetOf<String>()
        var visited = 0
        var length = 0
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (++visited > 1500 || depth > 40 || length >= 64000) return
            if (node.isVisibleToUser && !node.isPassword) {
                for (value in listOf(node.text, node.contentDescription)) {
                    val text = value?.toString()?.trim().orEmpty().take(4000)
                    if (text.isNotEmpty() && lines.add(text)) length += text.length + 1
                }
            }
            for (index in 0 until node.childCount) {
                if (visited >= 1500 || length >= 64000) break
                node.getChild(index)?.let { visit(it, depth + 1) }
            }
        }
        visit(root, 0)
        return VisibleScreen(source, label, lines.joinToString("\n").take(64000))
    }

    private fun captureScreen(scope: String, shadeChecksRemaining: Int = 5) {
        if (Build.VERSION.SDK_INT < 30 || instance !== this || MemoryStore.scope(this) != scope) {
            complete(null, "账号或截屏授权已变更，请重新记录")
            return
        }
        val activePackage = try { rootInActiveWindow?.packageName?.toString() } catch (_: Exception) { null }
        if (activePackage == "com.android.systemui") {
            if (shadeChecksRemaining > 0)
                main.postDelayed({ captureScreen(scope, shadeChecksRemaining - 1) }, 150)
            else complete(null, "请收起控制中心后重新记住屏幕")
            return
        }
        val visible = try { visibleScreen() } catch (_: Exception) { VisibleScreen() }
        try {
            takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(screenshot: ScreenshotResult) {
                    if (instance !== this@MemoryAccessibilityService) { screenshot.hardwareBuffer.close(); return }
                    var wrapped: Bitmap? = null
                    val bitmap = try {
                        wrapped = Bitmap.wrapHardwareBuffer(screenshot.hardwareBuffer, screenshot.colorSpace)
                        wrapped?.copy(Bitmap.Config.ARGB_8888, false) ?: error("无法读取本次截图")
                    } catch (_: Exception) {
                        complete(null, "无法读取本次截图，请重试")
                        return
                    } finally { wrapped?.recycle(); screenshot.hardwareBuffer.close() }
                    worker.execute {
                        var image: File? = null
                        try {
                            check(MemoryFrame.hasVisibleContent(bitmap.width, bitmap.height, bitmap::getPixel)) { "当前画面未允许截屏" }
                            val id = MemoryStore.newId()
                            val file = MemoryStore.imageFile(this@MemoryAccessibilityService, scope, id)
                            image = file
                            file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                            MemoryStore.save(this@MemoryAccessibilityService, scope, id, visible.sourcePackage,
                                visible.sourceLabel, visible.text, imagePath = file.absolutePath)
                            complete(id, null)
                        } catch (_: Exception) {
                            image?.delete()
                            complete(null, "本次截图未保存，请检查当前应用是否允许截屏后重试")
                        } finally { bitmap.recycle() }
                    }
                }
                override fun onFailure(errorCode: Int) {
                    complete(null, if (errorCode == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT)
                        "操作过快，请稍后再记住屏幕" else "当前画面无法截屏，请检查辅助截屏授权后重试")
                }
            })
        } catch (_: Exception) { complete(null, "辅助截屏未连接，请在截屏设置中重新启用") }
    }

    private fun complete(id: String?, error: String?) {
        main.post {
            capturing = false
            if (id != null) MemoryBridge.notifyChanged(id)
            Toast.makeText(this, if (id != null) "已存入 Orialis 记忆" else error ?: "截屏未完成", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onDestroy() {
        if (instance === this) { instance = null; capturing = false }
        main.removeCallbacksAndMessages(null)
        worker.shutdown()
        super.onDestroy()
    }
}
