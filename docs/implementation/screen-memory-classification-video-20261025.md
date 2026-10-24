# 屏幕记忆：AI分类、原视频直达与后台视频理解

状态：服务端和Azure Hermes插件已上线，公网分类、图片理解及B站视频理解验收通过；手机端待用户指定会话统一发布。B站412通过用户专门扫码授权及异常字幕处理修复，公网返回completed、category=ai、videoStatus=analyzed；详见 [最新视频验收](bilibili-412-diagnosis-20261025.md)。下文保留此前本机验收及原始功能记录。

来源：用户2026-10-25要求修复剩余测试，增加自动分类与AI栏目，获取原视频链接并在后台理解视频；追加参考 `github.com/c1overzz/dsh-bili-scroll`。执行范围为coder的屏幕记忆、对应服务端/插件链路及本轮已知失败测试，不改动其他并行产品改动。

## 功能

- 列表提供“全部 / AI”筛选，并与搜索组合使用；刷新保留选择。分类由后台模型判断，现阶段输出 `ai` 或 `other`。旧的已完成记忆如果没有分类，会通过新的稳定任务ID自动补分析。
- 列表和详情可直接“打开原视频”或“打开原链接”，不触发聊天或重复分析。原始分享链接及签名参数继续保存在记忆中。
- 来源优先使用分享内容中实际出现的URL、已捕获的BV号；截图中清晰可见的完整BV号可由视觉模型识别，再经B站接口核验。不会按标题搜索、猜测或拼接隐藏播放地址。
- 后台优先获取B站字幕；没有字幕时，从平台故事板选取3张画面并裁成JPEG交给视觉模型。分P链接按 `p` 参数选择对应CID。元数据/标题本身不算视频内容证据。
- 详情单独展示视频摘要；平台限制、无字幕/画面或模型未生成有效概述时，显示视频未完成的原因并允许重试。原图、分享文案、来源链接及已有摘要保留。
- 完成但视频不可用的任务重试会持久化新ID；网络断开后复用该ID取回结果。自动分类升级使用 `memory-v2-<record id>`，不覆盖旧聊天数据。

## 参考与能力边界

参考 [c1overzz/dsh-bili-scroll](https://github.com/c1overzz/dsh-bili-scroll)，核对提交 `5be5f6d57c47c7e79ad9bc4ce39457b68a160dfa`。采用其字幕优先、故事板抽样画面补充的技术思路；改编部分的MIT署名与完整许可保留在插件 `THIRD_PARTY_LICENSES.md`。

真实公共视频 `BV1d8pU6xEZX`（157秒）已测试取得故事板并裁出3帧，未返回字幕。随后在本机现有完整Hermes运行环境调用同一视频的真实视觉模型，返回 `category=ai`、`video_status=analyzed`，识别出了设置开关、关键词输入、手动运行DSH等画面内容，并明确未提供音频/完整字幕。该检查证明真实视频画面获取与模型理解链路，不等于生产Azure设备、服务器和手机端联合验收。

本轮首先完整支持B站视频内容证据。其他平台继续保存原链接并可跳转，视频理解显示当前支持范围。普通Android截屏不保证能读取其他应用内部未显示的链接。只理解实际拿到的字幕和抽样画面，不声称完整观看视频或听取音频；未加入语音转写或登录态绕过。

## ADR：结果携带分类和视频证据状态

沿用独立后台分析接口，增加可选 `sourceUrls` 输入，结果增加 `category/sourceUrl/videoStatus/videoSummary/videoError`。新增迁移 `0020_memory_classification_video.sql`，不修改已存在的0019迁移。旧客户端与旧结果字段仍可读取；新客户端用新版本任务ID补足元数据。

后台限定300秒，客户端等待310秒；字幕和画面读取有限时及大小限制。对读取的域名、公共IP及每次重定向做校验。服务器不写聊天或消息，只保存结果元数据及证据指纹。

## 剩余测试问题的处理

- 服务端并发测试注册超过全局鉴权哈希准入4个槽位，夹具却一律要求注册成功。改为测试夹具共享锁；生产鉴权、哈希参数和限流保持原样，并添加真实占满准入槽位时的拒绝测试。
- 旧日历迁移数量固定断言已在上一轮调整为真实迁移总数。
- Hermes原生重试夹具在macOS使用未规范化的 `/var` 临时路径，而回调使用 `/private/var`，导致原生会话身份匹配失败。仅统一测试夹具路径，不绕过会话鉴权。
- 插件测试所需pytest通过临时测试依赖目录提供，不改动用户现有Hermes运行环境。

## 验证记录

- 服务端默认并发完整回归：`cargo test -p orialis-server --offline`，147/147通过，用时685.01秒；包括此前失败的附件、任务、日历迁移测试，以及鉴权限流满载拒绝测试。无测试线程参数规避，生产鉴权源码保持不变。
- Hermes完整单元测试发现：135/135通过；协议fixture pytest：12/12通过。原先5项原生重试夹具错误及pytest环境缺失已闭环。运行依赖见 `integrations/hermes/orialis/tests/requirements.txt`。
- Flutter记忆页面、分析器、HTTP客户端及记录模型：38/38通过，日志 `/tmp/orialis-memory-flutter-20261025.log`。包含分类+搜索+刷新、单层容器、原链接精确保留与直接打开、视频摘要/重试、旧记忆分类升级、账号切换及中断恢复。
- Flutter相关源码和测试静态检查：无问题，日志 `/tmp/orialis-memory-analyze-20261025.log`。
- 协议校验：27个fixture、12个schema及多设备schema通过；本轮修改范围差异空白检查通过。
- 公共B站视频真实探测：157秒视频无可读字幕，实际获取3张故事板裁帧；在现有managed Hermes Python3.14环境调用真实辅助视觉模型成功，返回AI分类及视频概述。未读取登录Cookie或用户私人截图。

复现插件检查时可使用独立测试依赖目录和匹配的Hermes解释器：`python -m unittest discover -s integrations/hermes/orialis -t . -p 'test_*.py'`；另以 `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest integrations/hermes/orialis/tests/test_contract_fixtures.py -q` 执行契约fixture。测试环境依赖安装在临时目录，未替换正在运行的Hermes环境。

## 上线条件

需联合更新Orialis服务端（执行0020迁移）、Azure Hermes插件与手机客户端。插件视频抽帧需要Pillow。服务端与Azure插件已按 [部署记录](screen-memory-server-deployment-20261025.md) 更新，手机包未安装；原用户数据库原位应用新增迁移，未用备份覆盖新数据。
