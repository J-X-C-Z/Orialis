> 此16方案已撤回：用户明确要左上文字区域凸起，不是右上翘起。当前手机为17，见mobile-today-title-build17-20261026.md。

# Orialis 手机首页单角翘起试版 — build16

基于用户要求保留的build13。用户明确选择：只让一个角翘起，只先修改手机端。本轮将手机“现在关注／下一安排／最近截止／今日稍后”这一层四张大卡片的右上角做成柔和翘起，卡片主体保持平稳。

## 效果与范围

仅在原圆角外侧绘制局部弧面、柔和接触阴影和细边高光：上缘约7.5、外侧约3逻辑像素。颜色来自各卡片自身的蓝／绿／黄／紫色系。形状不覆盖原卡片内容，文字、按钮、命中区域与折叠状态逻辑不变。没有重做玻璃材质或移动整张卡片。

实际产品增量只涉及三个手机路径：`mobile/lib/pages/today/today_page.dart`接入、`today_corner_lift.dart`局部画笔、`mobile/test/today_corner_lift_test.dart`验证。通过Android/iOS平台且非desktopMode限定，Mac/Windows及桌面模式直接返回原卡片；高对比模式保留原卡片。本轮没有修改共享材质、导航或桌面代码，没有构建或部署桌面包。

## 验证

- 控件测试通过：翘角下方的恢复排序按钮仍可点，标题仍可折叠/展开；关闭效果以及Mac/Windows平台时无新增画笔，原卡片几何一致。
- 明暗视觉测试通过：4张真实Flutter渲染原图，字体/图标加载完成，无异常；未修图。原始对照见`corner-mobile-build16/contact-sheet.html`及`visual/`。
- 修改范围静态分析No issues found；git diff检查通过。早期临时截图字体及测试finder修正记录保留，最终成功日志以final命名。
- release arm64的Android独立测试包1.1.0+16已在有线Mi 10（df7020e3）覆盖安装；安装后APK SHA256一致，冷启动成功。实际浅色首页的四张卡片已查看，手机上也操作了“现在关注”折叠再展开并恢复原状态；进程范围日志未见FATAL EXCEPTION/Unhandled Exception/E/flutter。
- 独立测试包首次安装时间不变，正式包版本及安装时间不变。共享材质/导航/桌面源码哈希不变；Mac安装仍为原13且可执行文件哈希不变，Windows沿用上轮13目录和快捷方式。

## 当前版本

Android：`android/Orialis-UI-1.1.0-build16-arm64.apk`，只增加手机首页单角效果；APK SHA256 `818818b3353354f4aed061aad4104cfd2202571140d40afae58b4386db627e04`。Mac与Windows继续build13。

真实手机图：`corner-mobile-build16/android-native-overview.png`，折叠图`android-native-collapsed.png`。安装与边界证据`android/android-release-verification16.json`、`corner-mobile-build16/before.json`；3文件源码快照/哈希及Today接入差异在同目录。

用户否决的14/15材料方案仍为历史；本轮不使用14的性能数字作为16新测量。未测本轮实际帧耗时。没有清空账户数据、改后端或提交/推送/合并。
