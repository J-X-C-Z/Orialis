# 屏幕记忆：快捷截屏与保留原应用

> 1.1.0统一发布状态与使用说明见[版本记录](../releases/1.1.0.md)。下文保留各模块交付时的源码/部署验收边界。

本次只修改手机源码和执行编译/页面测试，未安装或发布手机包。后台标题与UP主搜索由对应视频模块处理。

Android 11及以上新增`MemoryAccessibilityService`，用户在记忆页面右上角“截屏设置”中选择“打开系统设置”，手动启用一次“Orialis 辅助截屏”。启用后，快捷键使用Android官方`AccessibilityService.takeScreenshot`，不再逐次发起MediaProjection授权。未启用或系统不支持时保留原有系统截屏确认，不能宣称可静默跳过系统强制授权。

辅助服务仅在明确点击记忆快捷键时读取截图和当前可见应用文字；`onAccessibilityEvent`为空，不持续记录屏幕。截图前等待透明快捷启动页和控制中心退出，控制中心仍打开时短暂重试后报错。只读取可见、非密码节点；原图、来源应用和可见文字进入既有账号隔离的MemoryStore。

快捷截屏和分享到记忆均不再启动MainActivity或发出记忆页面跳转。成功只反馈“已存入 Orialis 记忆”，随后保持原应用。未登录时提示手动登录，不主动打开App。后台理解使用保存钩子及独立后台分析任务，不应重新引入前台跳转。

桥接接口只新增`status.silentCaptureSupported`、`status.silentCaptureEnabled`与`openCaptureSettings`，未重构MemoryBridge构造器或headless逻辑。Flutter MemoryStatus新字段都有false默认值，兼容现有状态测试及后台桥。

记忆页面15项测试通过，包括授权入口不自动打开、明确点击后才进系统设置、已启用状态可管理授权；记录为`/tmp/orialis-memory-capture-page-tests.log`。Android原生`./gradlew :app:compileDebugKotlin --offline`通过，使用Android Studio自带JDK，记录为`/tmp/orialis-memory-native-compile.log`。尚未在实体手机启用新服务或验证具体ROM的控制中心动画；这一步应在手机统一发布后验收。

官方API依据：https://developer.android.com/reference/android/accessibilityservice/AccessibilityService#takeScreenshot(int,%20java.util.concurrent.Executor,%20android.accessibilityservice.AccessibilityService.TakeScreenshotCallback)
