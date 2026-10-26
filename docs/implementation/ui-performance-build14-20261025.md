# UI性能、阴影裁切与玻璃厚度修复（TASK-025 build14）

独立分支`codex/neumorphic-ui-test`；基线`817cc3c19c80ec66d850cd4734d44aad8f8ca1f2`。保留build12/13历史、原有账户与其他工作区，无提交、推送或合并。

## 改动

- 玻璃凹槽原来在不透明底色上再做一次实时背景模糊；移除这层无有效背景信息的重复过滤，磨砂承托改为直接绘制，文字仍保持清晰。
- 高性能模式真正跳过普通交互面的弹簧控制器；导航自己的跟手弹簧保留。轻拟态不再测量不会显示的肩部标题缺口；新材质渐变复用既有64项有界缓存。
- 聊天列表与卡片增加阴影留白，顶栏和输入区离开裁切边缘，页签去掉重复实线描边。公共轻拟态顶栏内收12，桌面首页两列滚动区各留16，避免阴影被截成直线。保留必要的视口裁切、焦点、选择、滚动与历史锚点。
- 玻璃由微弱描边改为实体侧面：顶面向上2.4、底座向下1.8逻辑像素，形成4.2的可见厚度；按下为0.45+0.65。侧壁、顶面高光和接触阴影分别表达高度，玻璃仍嵌在凹槽内。侧壁借现有裁切绘制，不在每帧执行布尔路径运算。
- 聊天气泡每次构建只解析一次时间；标准空附件直接返回空列表。消息协议、正文、附件归属、发送/重试与草稿规则未改。

## 前后测量

固定离线场景用真实Lumina控件、富卡和滚动列表，build13与14交替三轮，明暗和普通/高性能四种配置。此为**桌面Flutter测试环境的合成场景**，不是手机GPU/FPS或整个应用的耗时承诺。

| 项目 | build13 → build14 |
|---|---:|
| 活跃背景模糊控件及BackdropFilterLayer | 18 → 0 |
| ClipRRectLayer | 18 → 0 |
| PictureLayer | 87 → 47 |
| RepaintBoundary控件 | 12 → 12 |
| 固定更新工作量pump p50 | 减少8.8%–15.9% |

原始每轮数据、完整图层树与截图保存在`performance-build14/comparison.json`、各`*-paired*/widget-report.json`、`contact-sheet.html`。公共顶栏和桌面Today留白的最后改动不在该基准场景中；精确差异在`final-source-drift.diff`，没有把这些变化冒称测过性能。

Android真机profile已在有线Mi 10（df7020e3，90Hz）完成一轮build13→14配对，四种配置共两次通过。绘制线程p95由16.184–19.585ms降为9.797–10.242ms（下降37%–48%），构建或绘制超过11.11ms的帧占比由54.55%–61.26%降为1.87%–2.30%。构建p95并非全部改善（基线0.608–0.749ms，新版0.668–0.706ms）。这是固定离线真实控件场景的一轮配对，未控制热状态，不代表全应用FPS、实际掉帧率或纯GPU时间。原始逐帧数据、定义及限制见`performance-build14/android-profile-comparison.md/.json`和baseline/candidate-profile目录。独立基准不读取账户，结束后确认包已不存在，并移除本次两个本地调试转发。

## 视觉与功能验收

共享控件/配色5项、聊天42项、导航1项、无障碍及原材质10项通过，共58项。三轮配对基准12项检查及2次视觉运行通过；实际ChatPage深浅两项截图通过。完整分析无error/warning，保留6条既有info级建议；diffcheck通过。

真实聊天组件截图：`performance-build14/actual-chat-light-bottom.png`、`actual-chat-dark-bottom.png`及滚动截图。控件1倍和2倍原始对照在`candidate-visual/`与`baseline-visual/`。图片由Flutter直接渲染，未后期修图。

首次临时聊天截图夹具在框架收尾时留下Drift零时计时器；调整夹具提前卸载并排空后两项通过，失败日志`chat-visual.log`保留。该修复只在临时输出目录。

## 三端包与当前部署

| 平台 | 包 | 当前核验 |
|---|---|---|
| Android | `android/Orialis-UI-1.1.0-build14-arm64.apk` | release arm64成功；已在Mi 10有线安装独立包top.jxcz.orialis.neumorphic、versionCode14，安装后APK SHA256一致；冷启动/首页/空聊天入口/凸起玻璃已验收，正式版版本和安装时间未变 |
| Mac | `macos/Orialis-UI-1.1.0-build14-macos-universal.zip` | universal arm64+x86_64、严格签名通过，已安装；原build13完整备份；用户完成系统钥匙串确认后，build14真实首页/聊天/原账户/在线同步验收通过，已保存原生截图 |
| Windows | `windows/Orialis-UI-1.1.0-build14-windows-x64.zip` | 原生x64 release成功、1.1.0+14；564份相关源码哈希一致，完整61项ZIP校验通过；已部署独立目录和更新桌面快捷方式，真实GUI未验收 |

Mac安装位置`/Users/jxcz/Applications/Orialis.app`，上一版备份`macos/backup/Orialis-build13.app`。初次等待`flutter_secure_storage_service → SecItemCopyMatching`的进程采样在`macos/build14-startup-sample.txt`。系统凭据窗口禁止自动操作，用户随后亲自确认，已进入真实页面；不清除钥匙串、不绕过访问控制。本机签名未做DeveloperID公证。

Windows目录`C:\Users\Jxcz2\Documents\Orialis-Fusion-Test-1.1.0-14`，桌面`Orialis Fusion Test.lnk`指向最新版本。逐文件预检发现唯一例外为Android自动生成的Java插件注册文件：普通构建去掉integration_test测试插件，与Windows运行无关。已核对确切差异并单独记录expected/actual SHA256，没有将其宣称源码全一致；全部Dart/UI及Windows源码一致。详情`windows/android-generated-drift14.json`和`windows-release-verification14.json`。

Android14实际冷启动成功（本次1342ms，仅启动记录，不作前后性能对比）。独立测试版在Mi 10上没有账户或历史消息，因此仅验收真实首页与空聊天入口；未冒称登录聊天详情通过。应用进程范围日志未见FATAL EXCEPTION、Unhandled Exception或E/flutter。正式包top.jxcz.orialis保持1.0.1+3，安装和更新时间与本轮操作前完全一致。详情`android/android-release-verification14.json`。

## 交付与延续范围

`source/changed-files.zip`、`source/source.patch`、`source/manifest.json`包含最新可审阅源码；`performance-build14/build13-to14.patch`只列这轮7文件差异。各端与根目录SHA256SUMS保存校验和。`performance-build14/README.md`含完整复现步骤、场景和限制。

此前已完成：多色体系、新图标、12种SVG聊天符号、桌面独立排版及真实数据洞察、20类Intelligent UI与摘要展示。服务发布仍沿用原合作分工：生产discovery17、Linux20/6候选隔离通过但未生产切换；Windows共享Hermes忙，新final契约未启用。没有因本次UI性能优化重启共享服务。

本轮实现、58项针对性回归、三端构建、Android有线安装/真机专项profile及Mac原账户界面验收完成。仍未验收：Windows真实GUI、Mi 10登录聊天详情与完整跨设备聊天/摘要矩阵；既有共享服务限制另行保留。

Mac14最新原生验收：首页/两列滚动阴影、真实聊天列表/目录附件卡和玻璃侧壁已实际查看，原账户JXCZ保持登录、服务器在线、已同步。截图performance-build14/macos-native-overview.png和macos-native-chat.png。Android原生截图为performance-build14/android-native-overview.png和android-native-chat.png；原生结果按本轮真实设备Mi 10记录，不与此前Mi 13混用。
