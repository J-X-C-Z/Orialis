package top.jxcz.orialis

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private var wearBridge: WearBridge? = null
    private var systemBridge: SystemBridge? = null
    private var memoryBridge: MemoryBridge? = null
    private var chatShareBridge: ChatShareBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (packageName != "top.jxcz.orialis.news") {
            wearBridge = WearBridge(flutterEngine.dartExecutor.binaryMessenger, XiaomiWearAdapter(applicationContext))
            systemBridge = SystemBridge(this, flutterEngine.dartExecutor.binaryMessenger)
            memoryBridge = MemoryBridge(this, flutterEngine.dartExecutor.binaryMessenger)
            chatShareBridge = ChatShareBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "top.jxcz.orialis/haptics")
            .setMethodCallHandler { call, result ->
                if (call.method == "confirm") {
                    window.decorView.performHapticFeedback(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                            HapticFeedbackConstants.CONFIRM
                        else HapticFeedbackConstants.VIRTUAL_KEY
                    )
                    result.success(null)
                } else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "top.jxcz.orialis/updates")
            .setMethodCallHandler { call, result ->
                if (call.method == "getInstalledVersion") {
                    @Suppress("DEPRECATION")
                    val version = packageManager.getPackageInfo(packageName, 0).versionName
                    result.success(version)
                    return@setMethodCallHandler
                }
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val apk = path?.let(::File)
                val cache = cacheDir.canonicalFile
                if (apk == null || !apk.isFile || !apk.canonicalPath.startsWith("${cache.path}/")) {
                    result.error("invalid_apk", "APK must be in the app cache", null)
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                    startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                            .setData(Uri.parse("package:$packageName"))
                    )
                    result.success("permissionRequired")
                    return@setMethodCallHandler
                }
                val apkUri = FileProvider.getUriForFile(this, "$packageName.update-provider", apk)
                val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                    setDataAndType(apkUri, "application/vnd.android.package-archive")
                    flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(installIntent)
                result.success("opened")
            }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        systemBridge?.onNewIntent(intent)
        memoryBridge?.onNewIntent(intent)
        chatShareBridge?.onNewIntent(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        systemBridge?.onRequestPermissionsResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        chatShareBridge?.dispose()
        chatShareBridge = null
        memoryBridge?.dispose()
        memoryBridge = null
        systemBridge?.dispose()
        systemBridge = null
        wearBridge?.dispose()
        wearBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
