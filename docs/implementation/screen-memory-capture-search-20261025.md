# 屏幕记忆：安静截屏、原应用停留与标题/UP主匹配

> 1.1.0统一发布状态与使用说明见[版本记录](../releases/1.1.0.md)。下文保留各模块交付时的源码/部署验收边界。

状态：服务器已上线并通过公网完整验证；手机源码已完成，48项相关测试、静态检查与Android原生编译通过，未安装手机包。具体ROM的授权、快捷键和冷进程执行仍待手机统一发布后验收。

## 用户行为

Android 11及以上，在记忆页右上角“截屏设置”中手动启用一次“Orialis 辅助截屏”，之后快捷键不再每次发起系统录屏授权。未启用时仍保留系统要求的截屏确认，不能隐藏或自动批准。服务仅响应用户点击，不持续读取屏幕；保存成功后只提示已保存，不启动Orialis界面，分享到记忆也同样处理。

保存后系统调度短期后台任务，复用原有安全登录存储和独立记忆API，前台界面未运行也可处理。后台引擎结束即释放，不生成聊天消息；账号切换和新重试均能取消旧结果写入。系统省电及任务额度可能影响实际启动时机。

没有原链接或完整BV号时，AI抄录同一B站视频的可见标题与UP主。后台向B站视频搜索接口发出一页、有界查询，只有唯一同时匹配的结果才继续，并再次用视频详情核验标题、UP主和BV号，再取得字幕或故事板理解。标题或作者不清晰、搜不到、多个候选时保留截图，提示分享原链接；其他平台不套用B站搜索。

## 服务器发布与验证

只替换`memory_video.py`和`memory_analysis.py`；没有发布其他会话的新adapter/response_ui代码，也没有修改Rust服务、数据库或线协议。发布目录为`/home/hermes/.hermes/releases/orialis-memory-capture-search-20261025-030345`，同目录`production-backup`保存这两个文件的原始副本。若需要回滚，仅原子恢复这两个模块并重启Hermes，勿恢复整个旧插件或数据库。

最终SHA256：

- memory_video.py：57bf16de1aeb44038fdb00ec879c4afd2b6bbbd098be97e1478e679b659864ab。
- memory_analysis.py：1625cd783aad6fc786cfc460915cad5036254bb58b17a1ee7f73af10d9c600d7。

真实B站查询只提供视频标题和“凌羽clover”，没有传入URL或BV号，成功核验BV1d8pU6xEZX并取得37、75、115秒的故事板。随后使用受控截图夹具（显示真实标题、作者和视频画面，不显示URL/BV）完成实际模型OCR、真实搜索与视频理解，92.14秒返回analyzed/category=ai。

发布后，Mac通过公网正式API提交同一受控截图，sourceUrls为空，返回completed、category=ai、videoStatus=analyzed、正确sourceUrl和非空videoSummary。重复POST复用1条任务，临时测试Session与任务均按精确ID清理，无对应测试聊天记录。此为真实服务器/模型/平台链路验证，输入图为受控夹具，不声称已经做过实体手机新版本截图验收。

最终API PID1713674未变、Hermes PID1739319；两服务均active/running、NRestarts=0，网关connected，本地`/api/health`为200。其他插件源码逐字节保留，最终发布未触发回滚。

## 检查与交接

后台51项相关单元测试通过，覆盖WBI签名、唯一匹配、错误UP主、多候选、详情复核、可见长标题截断及旧URL/BV优先。手机48项相关测试通过，涵盖授权设置入口、保存/分析、后台入口、账号变更、旧任务迟到与原生比较后写入；Dart analyze无问题，Android compileDebugKotlin通过。没有为隐藏系统授权而修改手机系统或安装权限工具。

证据在`projects/orialis/deliveries/screen-memory-capture-search-20261025/`：`search-reader-verification.json`、`ocr-search-verification.json`、`promotion.json`、`postflight.json`、`acceptance-public.json`、`backend-tests.log`、`mobile-*.log`、`mobile-source-manifest.json`。手机统一发布见同目录`mobile-handoff.md`；原生与后台实现分别见`screen-memory-capture-quiet-20261025.md`和`screen-memory-headless-20261025.md`。

决策依据见`docs/decisions/20261025-screen-memory-capture-and-video-matching.md`。Android能力依据为[AccessibilityService.takeScreenshot](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService#takeScreenshot(int,%20java.util.concurrent.Executor,%20android.accessibilityservice.AccessibilityService.TakeScreenshotCallback))与[MediaProjection用户同意要求](https://developer.android.com/media/grow/media-projection#user_consent)。B站接口及签名参考已校验PyPI17.4.1发行包的search API定义和公开WBI协议常量，未将SDK加入生产Hermes运行环境。
