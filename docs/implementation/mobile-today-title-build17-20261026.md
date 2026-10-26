# Orialis 手机首页左上标题凸起 — build17

用户最新纠正：不是翘起，而是凸起；左上角“现在关注”这种文字部分，要与其他地方拉出一点层级区别。沿用只修改手机端的限定。

## 当前效果

移除build16右上角外翘的绘制和包装。“现在关注／下一安排／最近截止／今日稍后”四张大卡片的左上标题与折叠箭头放在同色轻拟态凸起台面中，使用16逻辑像素圆角、水平12/垂直10内边距；光影复用已有raised材质。卡片外轮廓平整，内容与右侧操作保持原有层级和行为。

复用现有LuminaCardHeader、LuminaCollapsibleCard的折叠、动画和持久化。共享标题新增可选raisedTitle参数，默认false；仅Today的Android/iOS且非desktopMode启用，非轻拟态/高对比回退原标题。没有改变默认桌面外观，没有构建或安装桌面包；Mac、Windows仍build13。玻璃画笔和导航未改。

源码修改4文件：mobile/lib/pages/today/today_page.dart、packages/lumina_ui/lib/src/design_components.dart、packages/lumina_ui/lib/src/lumina_patterns.dart、mobile/test/today_title_relief_test.dart。删除已撤回的today_corner_lift.dart及对应测试，原16源码已保存在title-mobile-build17/baseline16/。

## 验证与安装

共享控件/配色5项、新标题交互和实际Today平台边界2项、明暗真实渲染1项，共8项独立检查通过。两倍文字下标题和箭头位于凸起表面内，右侧操作独立可点，折叠/展开仍可用；实际Today在Mac/Windows与desktopMode不启用标题凸起。修改范围分析No issues found；diff检查通过。

浅色/深色原标题与新标题真实渲染4张原图保存在visual/，未修图；contact-sheet.html可直接对照。

Android独立测试包1.1.0+17已在有线Mi10(df7020e3)覆盖安装，安装后SHA256与交付APK一致；冷启动成功。实机浅色首页已查看左上标题凸起和恢复平整的右上角；“现在关注”原本收起，检查时展开再收起，恢复原状态。进程范围日志没有FATAL EXCEPTION/Unhandled Exception/E/flutter。首次安装时间及正式包版本/安装更新时间未变。

APK：android/Orialis-UI-1.1.0-build17-arm64.apk，SHA256 `c0a75cd40b5bd7a659c7d5bb086b8993a358fe9588b2891ecf8a55dcf22f10cc`。安装证据android/android-release-verification17.json。

实机图：title-mobile-build17/android-native-overview.png、android-native-expanded.png。精确源码快照/哈希source/、source-manifest.json及build16-to17.patch在该目录。安装后再次核对原玻璃画笔、导航、desktop_shell源码哈希和Mac13可执行文件哈希未变；本轮未操作Windows。

本轮未做新帧耗时测量，不能使用历史14的数字代表17。没有改后端、发送测试消息、清空数据或提交/推送/合并。全量可审阅改动在source/changed-files.zip和source/source.patch。
