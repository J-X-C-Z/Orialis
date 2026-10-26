> 当前状态（2026-10-25）：用户否决build15，已回退build13。14/15描述仅为历史方案；见rollback-build13-20261025.md。

# Orialis 加厚嵌入玻璃 — 1.1.0 build15

用户纠正：“不是上抬，而是一个更厚的效果。”本轮只修改共享嵌入玻璃材质，三端使用同一实现。分支`codex/neumorphic-ui-test`，未提交、推送或合并。

## 本轮效果

取消build14玻璃顶面向上偏移和底座向下偏移。底座及外轮廓固定在原凹槽内，玻璃厚度由轮廓内部更宽的曲面倒角、透光侧壁与下缘折射带表达。正常状态下缘厚度5.6逻辑像素，按下3.2，小控件按短边最多18%收缩。内容、点击区域、布局与导航三层同步位置沿用原实现。

这属于共享画笔的光学材质表现，不是真实三维几何折射；没有添加新的BackdropFilter或额外图层。build14的缓存、减少模糊及边界留白保留。

真实渲染对照：`thickness-build15/contact-sheet.html`，浅色/深色、普通/高性能、1倍/2倍共8张原图。窄线轮廓改为有宽度的玻璃侧壁；没有通过移动整个控件制造高度。

## 验证与交付

本轮共享控件5项、导航长按拖动/释放/键盘/2倍文字1项通过；导航原始预览按预期更新；视觉测试1项通过，8张原图无渲染异常。共享包分析No issues found，diff检查通过。源码实际增量见`thickness-build15/build14-to15.patch`，只涉及lumina_material.dart。

|平台|版本与结果|
|---|---|
|Android|独立测试包1.1.0+15已在有线Mi 10安装，安装后APK哈希一致，冷启动与真实首页/空聊天入口通过；正式版版本及安装时间前后未变|
|Mac|universal arm64+x86_64 build15已签名校验并安装，build14完整备份；用户亲自完成系统钥匙串确认后，真实首页/原任务/已有聊天附件与输入框加厚材质验收通过|
|Windows|build15构建与独立部署进行中|

Android：`android/Orialis-UI-1.1.0-build15-arm64.apk`，验证`android/android-release-verification15.json`，真机图`thickness-build15/android-native-overview.png`及`android-native-chat.png`。该手机独立测试版尚无账户和历史消息，未冒称登录聊天详情验收通过。

Mac：`macos/Orialis-UI-1.1.0-build15-macos-universal.zip`，安装`/Users/jxcz/Applications/Orialis.app`，上版备份`macos/backup/Orialis-build14.app`；验证`macos/macos-release-verification15.json`。

## 性能与已有边界

build14曾有58项针对性回归、三轮主机合成对比及Mi 10一次真机profile配对；本轮沿用这些优化，但没有重新测量build15帧耗时，不能把14的37%–48%绘制p95改善宣称为15的新测量。build14详细报告保留于`thickness-build15/REPORT-build14.md`、源码实施记录与`performance-build14/`。

Windows真实GUI、Mi 10登录聊天详情及完整跨设备聊天/摘要矩阵仍缺。既有生产discovery17、Linux20/6候选未生产切换及忙碌Windows Hermes契约限制沿用前次报告；本轮未改后端或重启共享服务。

`source/changed-files.zip`、`source/source.patch`、`source/manifest.json`保存最新可审阅源码；历史包与校验记录保留。
