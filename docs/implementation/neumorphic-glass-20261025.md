> 当前状态（2026-10-26）：手机19将18的左上凹陷玻璃标题扩展到其他页面；Mac/Windows仍13。见mobile-sections-glass-build19-20261026.md。

# 轻拟态与液态玻璃融合

用户指定先部署纯轻拟态，再参考 [Glassy UI](https://glassyui.com/) 增加交互玻璃，要求凹陷底座、清晰内容和玻璃盖的三层组合，并在导航拖动时同步移动凹陷与玻璃。TASK-024 的独立包已安装启动，初始APK和源码快照保留在 `deliveries/neumorphic-ui-20261025/`。

工作区和分支仍为 `ui-neumorphic` / `codex/neumorphic-ui-test`；初始1.1.0基线不变。本阶段由 TASK-025/COORD-021 记录，Intelligent UI与聊天升级由用户指定的会话 `01a17183-13b2-7ff3-86ed-b7243cd5149a` 合作，独占 `mobile/lib/features/chat/**`、`mobile/lib/pages/chat/chat_page.dart` 及对应测试和协议文档。主会话负责共享材质、主应用主题、底部导航及统一APK。

## 分层

共享组件 `LuminaGlassWell` 在内容下绘制同色内阴影与局部磨砂，`LuminaGlassCoat` 在内容上方绘制低透明度的玻璃面、高光与边缘。上盖忽略指针和焦点；真实控件保留输入、点击和语义。`LuminaGlassSandwich` 组合三层；开启 `LuminaThemeData.neumorphicGlass` 后，交互型 `LuminaSurface(glass:true)` 自动使用该材质，普通阅读卡片保留轻拟态。

磨砂位于文字下，文字不被 BackdropFilter 模糊。高性能模式降低局部模糊，减少透明度或高对比度时使用实色承托与焦点边界。

导航和分段选择上下两个视觉层读取同一 `LuminaSpring` 位置，凹陷边缘稍大于玻璃上盖。拖动实时更新同一几何位置，中间文字层保持清晰；松手才切换页面，取消回到当前项，禁用项不提交。沿用现有弹簧参数和减少动态设置，不引入新动画依赖。

这里使用Flutter画笔的玻璃高光和局部磨砂，未引入网页WebGL渲染器，不宣称是物理光学折射。

## 验收

- 融合与纯轻拟态明暗控件回归、既有液态玻璃回归：12项通过。
- 导航凹陷与上盖跟手位置一致、五页功能、实际软件截图验收：3项通过（86秒）。已人工查看浅/深、编辑表单、窄屏及导航拖动截图，文字清晰；上盖是渐变高光与边缘，底部为局部磨砂。
- Intelligent UI与摘要集成、三端原生构建已完成；设备读回边界见下方最终交付记录。

## 新功能协作

用户另指定“探索先简短回应再完整输出”会话 `01a16ed1-e1b3-7cd0-a2c9-50152d34c4a7` 负责其新增摘要功能适配：自然摘要、最终回复关联识别、自动折叠/手动展开、摘要隐藏时间和静默通知。聊天负责人集成共同展示入口，摘要负责人交接精确已测补丁，避免同文件覆盖；这些客户端行为已由聊天负责人集成并完成联合回归；服务端运行范围和原生设备验收另行记录。

## 配色、符号与桌面扩展

用户追加授权多色体系、统一新图标、Mac/Windows新UI与聊天/摘要功能、大屏独立布局、SVG动画替代界面装饰emoji。六组语义卡面复用ocean/sage/amber/rose/lavender/mist，明暗卡面的主字/辅助字对比度测试均达到4.5；Today分区具不同意义的色面，桌面与手机共用。

新O形玻璃标识由内置imagegen生成，原始图与最终提示词保存在交付branding目录；Android、macOS和Windows资源已生成，旧品牌原图保留。

新增12种SVG符号与4个独立SVG动画预览。Flutter使用同源静态SVG加本地动画，语义化配色和减少动态设置；用户正文不改写。

桌面新增第十项聊天、Mac Command和Windows Control快捷键、滚动侧栏和宽/中/窄窗口布局。1440px以上的非聊天工作区有真实本地数据洞察栏，包含完成环、象限分布及近期日程；不使用假数据。聊天负责人独立实现会话列表/对话双区和宽屏富卡。

Mac与Windows原生构建均已完成；三端软件包与各端安装/启动边界见下方记录。

## 大屏与符号验证增量

- 配色与纯/融合控件的最终定向回归5项通过；六种明暗色面文字对比度均至少4.5。
- SVG符号5项功能断言通过（加载、映射、明暗、减少动态/语义、独立动画清单）；首次测试的SemanticsHandle释放位置已修正。
- 桌面键盘/焦点16项通过（Command/Control、输入保护、弹窗/认证和卸载边界），Provider能力声明检查通过。
- 桌面洞察、跨端主题/路由与原桌面流程最终6项全部通过。此前测试夹具的页面构造、流清理、可见性和语义边界问题已修正，初始失败日志保留。
- 1600/1180/860px真实Flutter组件预览流程通过，已查看浅色/深色、任务四象限和上下文数据截图。预览使用内存数据库合成数据，和原生设备窗口运行分开记录。

## 原生交付记录 — 1.1.0 build 12

- Android release arm64成功，独立包名 `top.jxcz.orialis.neumorphic`，产物已复制并生成SHA256。纯轻拟态build11此前已在原手机安装启动；融合build12的当前连接设备`df7020e3`为USB调试unauthorized，尚未安装，未动正式包。
- Windows x64 final native release成功。远端566份源码逐个SHA256吻合冻结清单；PE x64、版本1.1.0+12、完整运行目录61项压缩文件及归档哈希均已核对。独立部署到`C:\Users\Jxcz2\Documents\Orialis-Fusion-Test-1.1.0-12`，桌面`Orialis Fusion Test.lnk`已生成；尚未完成Windows真实GUI验收。
- Mac universal arm64/x86_64 release成功，版本1.1.0+12，源产物/暂存/已安装应用均通过`codesign --verify --deep --strict`。原`/Users/jxcz/Applications/Orialis.app`为1.0.0+2，已完整备份到交付目录的`macos/backup/Orialis-before-build12.app`，新应用已安装。
- Mac实际启动黑屏；进程采样明确落在`flutter_secure_storage_service → SecItemCopyMatching → securityd`，Dart启动在等待已有账户的钥匙串读取。系统SecurityAgent窗口禁止自动操作，已请求用户在系统提示亲自允许。尚未验收Mac真实界面、任务创建持久化或真实聊天；不清除钥匙串、不切换账户来绕过。
- Mac首次SPM解析CSQLite停滞，停止该构建并以项目级`flutter.config.enable-swift-package-manager: false`使用已有CocoaPods流程后成功；锁文件同步。Android/Windows已构建的pubspec不含此后增加的Apple依赖方式设置；运行Dart/UI与平台相应源码一致，平台差异列入交付清单，不重复构建不受影响的平台。

## SVG聊天符号交付

12种符号：思考、检索、处理、完成、错误、附件、摘要、图表、代码、发送、复制、提示。思考/检索/处理循环轻动效，完成一次入场；频繁静态控制保留静态。Flutter加载同源SVG并运行原生动画，独立SVG预览用SMIL，不宣称Flutter直接运行SMIL。明暗、减少动态、应用前后台及可访问性标签已覆盖；聊天正文和未知emoji保持原样。

符号整套实际浏览器截图位于`deliveries/neumorphic-glass-20261025/preview/chat-symbols.png`，离线动画展板为`symbols/index.html`。新图标的主PNG、生成提示词与工具来源保存在branding目录。

## 协作服务边界

客户端20类Intelligent UI和六种图表已集成并经过定向回归。服务负责人已完成精确现网源码Linux候选的隔离验收；现网能力发现最新仍为17类。共享Windows Hermes有活跃任务，本轮不重启Windows或共享Rust gateway，避免中断已有消息流。自然摘要/final关联的后端在Mac/Aozora/Hakari有验证，Windows共享运行时的新final契约仍未启用。最新服务验收以`deliveries/intelligent-ui-board-20261025`与`deliveries/summary-value-20261025`各自证据为准。

最后一次原生界面观察返回Mac已锁屏，无法继续自动检查；待用户亲自解锁并完成系统钥匙串提示。未尝试绕过锁屏或凭据窗口。

## 服务候选验收增量

已直接读回聊天负责人的`evidence/server-remote-preflight.json`及`server-final-runtime.json`：Linux x86_64 ELF候选sha256为`6e22cc0ebf80c91a22b01ff40c7b5071835fb156f8805756a5ecb9f9f58036d8`，Aozora隔离production-auth实际启动成功，能力发现20类/6图表，受保护memory路由返回401，21个迁移版本一致。候选位于`/opt/oris/releases/intelligent-ui-20-20261025/oris-server.candidate`。

生产未切换，现网仍17类；MainPID1713674/NRestarts0/active，临时隔离数据库已清理，回滚备份保留。服务候选验收通过不等于生产已升级；20类测试消息已由聊天负责人发送并完成精确读回（见下方记录）。

## 20类测试消息实际送达

已读取`deliveries/intelligent-ui-board-20261025/evidence/upgrade-send-result.json`：20类单消息已送达现有「Azure 服务器」会话，消息ID`intelligent-ui-upgrade-catalog-20261025-de77d1e8315c`。含3份UI文档与5份真实附件；gateway received ACK、移动WebSocket精确正文/附件、公开历史精确读回、5份附件下载的大小/SHA256均验证通过，临时观察会话已移除。此为真实传输与持久化验收，仍不等于新包在用户设备上的渲染验收。

`aozora-native-reconnected.json`确认发送后原生orialis-hermes-plugin1.0.0已恢复online/connected，PID1828207保持，未重启共享gateway。生产discovery仍17类；20类候选已隔离通过但未生产切换。

## build13最终材质与原生增量

用户最新要求“玻璃嵌在里面，顶面略高”已在共享材质两文件实现；色面同色内阴影和短侧壁参数、明暗预览见deliveries/neumorphic-glass-20261025/material-build13。5共享回归+2真实预览通过，定向分析无问题。三端build13原生包均构建成功，Android已安装并版本/hash/冷启动/原生首页验收；Windows565源码吻合、便携部署，GUI未验收；Mac13已签名安装，首次启动再次等待用户钥匙串。

此前Mac12钥匙串阻塞已由用户解除，真实原账户/任务/洞察/聊天/目录5附件可见；手动测试事项保存、PID变化后的重启保留和软清理已验证。Android12原生聊天目录可见，正式应用版本/安装时间在升级13前后均未改变。Mac13不可直接继承Mac12的GUI通过结论。最新总报告是deliveries/neumorphic-glass-20261025/REPORT.md，旧记录为历史状态。

## Mac13授权后验收

用户完成系统钥匙串允许后，已直接查看build13新材质首页、原有任务/真实统计，profile确认JXCZ保持已登录、服务器在线且已同步。安装版本13及严格签名再次核验通过，实际截图deliveries/neumorphic-glass-20261025/preview/macos-native-build13.png。Mac13基本原生GUI阻塞解除；完整聊天/摘要矩阵、WindowsGUI与共享服务发布边界仍未扩大宣称。

## build14性能与边界修复

用户进一步反馈整体性能、聊天等控件的硬隔断及玻璃仍平齐。本轮7文件实现与三端构建完成；移除不透明凹槽上的无效背景过滤、渐变缓存/控制器/文字测量优化、聊天与公共顶栏/桌面列阴影留白、4.2逻辑像素实体玻璃侧壁。58项定向回归及合成前后对比/实际ChatPage明暗截图通过。固定场景18→0背景模糊层、87→47绘制层，测试环境pump中位耗时下降8.8%–15.9%；未有手机GPU数据。完整证据和当前安装/设备阻塞见ui-performance-build14-20261025.md及交付最新REPORT；早期build13记录为历史。


## Build14最终增量验收

Mi 10有线完成一轮基线/新版离线profile对比；绘制p95约下降37%–48%，超11.11ms帧占比约55%–61%降至约2%，仅限固定专项场景与单轮配对。正常独立测试包14已安装，APK哈希一致，冷启动/首页/空聊天入口通过；正式版版本与安装时间不变。Mac14原账户/首页/真实聊天/在线同步通过；Windows14独立部署，窗口内验收仍缺。见ui-performance-build14-20261025.md及交付目录android-profile-comparison.md。


## Build15：玻璃本体加厚（取代build14上抬方案）

用户最新明确纠正要玻璃本体更厚。共享嵌入玻璃取消face向上与seat向下偏移，外轮廓固定在凹槽内，改用内部宽倒角/侧壁和下缘折射带，正常5.6、按下3.2逻辑像素，小控件按短边18%限制。文字、命中区域和导航三层同步逻辑保留。最新方案详见embedded-glass-thickness-build15-20261025.md；build14上抬数值仅是历史实现，不再是当前设计。
