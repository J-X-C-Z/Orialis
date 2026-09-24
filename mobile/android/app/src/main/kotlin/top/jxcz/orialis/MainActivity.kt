package top.jxcz.orialis

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import android.view.HapticFeedbackConstants

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
