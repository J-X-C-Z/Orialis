# Orialis 手机左上标题凹陷玻璃 — build18

用户将17的凸起区域改成“凹陷加玻璃效果”，沿用仅手机端。四张首页大卡片左上角的标题与折叠箭头保留位置、范围和内边距，材质改成原13已有的凹陷磨砂底座、文字中层与玻璃盖层。

共享标题的可选参数从raisedTitle改名glassTitle（默认false），只在Android/iOS非desktopMode的Today启用。渲染由原LuminaSurface玻璃夹心实现，depth=recessed、glass=true、radius16、padding12x10。玻璃画笔、导航和大卡片底面未改；Mac/Windows包仍13，本轮无桌面构建/部署。

两项专项测试通过：明暗主题下2倍字号、文字在标题表面内、凹陷深度与Well/Coat层真实存在、右侧操作与折叠独立；实际Today在桌面平台与desktopMode不启用。明暗原图渲染1项通过，共3项。范围分析No issues found，diff检查通过。预览为真实控件直接渲染，见contact-sheet.html和visual/。

Android18已安装，安装后APK哈希匹配，首次安装时间与正式包版本/安装更新时间不变；活动启动成功，设备当前锁屏，因此未把它写为真实界面验收。进程范围日志未见fatal/Flutter异常。已请求用户解锁，界面检查待完成。本轮未做帧耗时新测量，不借用历史14性能数据。

APK：android/Orialis-UI-1.1.0-build18-arm64.apk，SHA256 fd10878b573b52a588829fecc6a7a67e8df32918a3da51a80e4bbb0edc47ea23。详细安装证据android/android-release-verification18.json；原玻璃画笔/导航/desktop_shell及Mac13二进制hash不变。

后续补验（2026-10-26）：用户解锁并重连手机后，18的Today凹陷玻璃标题实际画面已确认；随后手机升级19扩展其他页面。见mobile-sections-glass-build19-20261026.md。
