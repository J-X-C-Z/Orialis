package top.jxcz.orialis

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build
import android.view.HapticFeedbackConstants

class MainActivity : FlutterActivity() {
    private var wearBridge: WearBridge? = null
    private var systemBridge: SystemBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (packageName != "top.jxcz.orialis.news") {
            wearBridge = WearBridge(flutterEngine.dartExecutor.binaryMessenger, XiaomiWearAdapter(applicationContext))
            systemBridge = SystemBridge(this, flutterEngine.dartExecutor.binaryMessenger)
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
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        systemBridge?.onNewIntent(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        systemBridge?.onRequestPermissionsResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        systemBridge?.dispose()
        systemBridge = null
        wearBridge?.dispose()
        wearBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
