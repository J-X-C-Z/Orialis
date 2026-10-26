# Orialis 当前状态：已回退 build13

用户明确否决加厚效果，要求“改回到上上个版本”。按当时当前build15往前两版，恢复build13；停止14/15方案作为当前版本。

|平台|回退结果|
|---|---|
|Android|Mi 10有线使用保留的原始build13 APK覆盖回退成功；读取安装包SHA256与原13一致，冷启动通过并实际查看首页；独立测试包首次安装时间不变，正式包版本及安装时间不变|
|Mac|恢复保留的原始build13 universal应用，严格签名验证通过；真实启动和原有任务5/11、首页及洞察已查看；被拒绝的15完整应用另行备份|
|Windows|快捷方式切回原始13独立目录；PE x64、1.1.0+13及完整目录61/61文件与保留13ZIP一致；15仅编译完成，未打包或部署；未做Windows真实GUI验收|

源码同样精确恢复到build13：将14/15改变的7个文件逐一按build13冻结哈希还原；被覆盖的15源码在`rollback-build13/rejected-build15-source/`保留。其他功能与无关工作未改，没有提交、推送或合并。

账户与数据保留；没有卸载/清空应用、重置钥匙串或改动后端。此前14的性能测量、15视觉方案及安装记录均保留为历史，不再代表当前13的效果与性能。

验收证据：`rollback-build13/source-rollback.json`、`android-rollback.json`、`macos-rollback.json`、`windows/rollback-build13.json`。实际截图`rollback-build13/android-native-restored.png`和`macos-native-restored.png`。

当前安装包：`android/Orialis-UI-1.1.0-build13-arm64.apk`、`macos/Orialis-UI-1.1.0-build13-macos-universal.zip`、`windows/Orialis-UI-1.1.0-build13-windows-x64.zip`。
