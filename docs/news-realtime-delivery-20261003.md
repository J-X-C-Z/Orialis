# AIHot / GitHub 生产交付 — 2026-10-03

用户回复“部署”授权经审阅上线范围。生产服务、Nginx、Android News与统一macOS包已更新。应用户最新要求，执行端已从本机迁至 Azure/Aozora Hermes；AIHot 生产发布和 5 分钟定时已通过验证。GitHub 榜单可采集，但本次 Azure Hermes 输出未能稳定通过完整 JSON 校验，GitHub 日/周定时保持关闭，不将降级结果记作分析完成。任务完成回报永久修复已通过真实闭环，三条定时触发器仍关闭；手机/桌面原生页面尚未验收。源码权威为当前Lumina-UI@d586222脏工作树，保留所有其他并发改动，本轮未提交或推送。

## 已上线结果

- AIHot：热点10、精选100、日/周/月报告各1、10个事件详情；不调用LLM。数据集独立失败，空/异常数据保留旧缓存。实际Paperclip process执行12:43:58–12:45:13Z，15个生产发布任务全部succeeded，缓存和publish result相同，无stale/error。
- GitHub：日榜19、周榜18，独立新采集，前10基于metadata/README整理。首次模型180秒超时，已明确发布降级事实榜；实际retry以540秒有界Runner/900秒process运行，12:49:38Z和12:50:00Z均成功、中文总览complete，每期有事实依据的9项生成摘要，缺资料条目保持null。原始排名/metadata保留。后续自动recovery重复两次也成功，已如实记录，不能说其已取消。
- 实时：Session鉴权SSE失效通知，持久metadata revision、Last-Event-ID重连、账号/地址变化清屏、后台取消及30秒轮询兼容。实际生产Dart鉴权stream200已观察，仅证明传输；UI未独立区分SSE/轮询。架构见项目decisions/ADR-010-news-snapshot-invalidation.md。
- 推送范围为App内刷新；不包含APNs/FCM、系统后台通知或历史逐条事件重放。

## 生产发布与回滚

20261003T123210Z在Aozora切换Linux ELF x86-64服务。18/18既有迁移checksum一致，三次health200、匿名stream401、active、PID2387161稳定且NRestarts0；公网最新读回仍200/401。新版本/旧版回滚：

- /opt/oris/bin/oris-server.news-realtime-20261003T123210Z
- /opt/oris/bin/oris-server.rollback.news-realtime-20261003T123210Z

Linux SHA256：37774ce1ce66f3897198991fa92dc49b6452a426fdf891222d98384a7373082e。只修改News SSE的Nginx exact location，buffering off，配置测试与reload成功，其他Gateway路由保留。

公网Python默认User-Agent触发Cloudflare1010；worker显式使用真实产品标识Orialis-News/0.1后通过。无凭据旋转/输出，publisher通过Paperclip Orialis公司local_encrypted secret reference注入，并绑定既有发布用户；私有runtime.env为0600、父目录0700。

## 运营任务

原AIHot process及独立GitHub Daily/Weekly process均已绑定实际publisher、既有本机Codex登录/模型、独立ledger目录。Projects例程、原Hermes研究员及其他公司配置保留。实际运行已验证采集、secret注入、中文分析和生产publish；原降级issues取消并标注被retry取代，成功issuesdone。

发现process exit0未回报issue disposition，Paperclip自动recovery会重复运行。永久修复已写入integrations/news/worker.py并切换三个实际worker配置：按自身run解析issue，验证company/project/assignee/指定routine；持久成功结果后回报done，恢复只补状态。未知AIHot running无确认回执时保持blocked，不自动重发。完整Python资讯43项通过，独立核心11回归与diff检查通过；实际AIHot闭环已通过：自身harness JWT读取run/issue、scope核对、checkout、生产publish、持久receipt、自主PATCH done/comment，heartbeat exit0/succeeded、ORI-83 done；完成后约141秒只有一个run，无automatic recovery重跑。

初始实现的三个触发器由本机Paperclip执行；依用户后续要求，资讯执行端已迁至Azure Hermes。最终Azure timers已启用：AIHot每5分钟、GitHub日报每日18:00、周报每周一18:15（Asia/Shanghai）。手机/桌面原生页面及自动刷新观察仍需真实前台验收。

## 客户端

Android仅覆盖top.jxcz.orialis.news，签名一致、firstInstallTime保留，未清除账户偏好或覆盖主App；旧APK已备份。新APK SHA256：5ff7c4d82071e38788bf038abff211e336b07145861e68cec9875b6d53407ab2（arm64 debug）。

统一桌面安装在~/Applications/Orialis.app，x86_64/arm64、adhoc严格签名检查与候选文件hash一致，旧包已保存；zip SHA256：ace62d4195fcf2122ecb008c0445244e6fb2bc780b5ac59a804381c4edcfcde0。不是另造macOS News App。

手机发布前真实空页已观察，持续前台自动更新观察和最终恢复读回都被用户切到其他App打断，已停止抢占，不将安装或server receipt当原生送达。Mac可能等待系统钥匙串授权，工具禁止操作SecurityAgent；仅进程启动、标题栏/黑色画面不能当页面验收。已向用户请求手机News前台一分钟及Mac授权处理。

## 验证与证据

原本机75项专项（Rust15/流水线28/来源8/Flutter24）与定向静态检查通过；Linux同15项专项通过。真实来源+中文分析已在临时DB由双HTTP SSE客户端接收、GET排名/简报一致、重启持久恢复通过。发布追加流水线与生命周期43项通过；代码差异空白检查通过，不冒称整个dirty仓库全套测试成功。

生产证据位于news/evidence/：

- realtime-production-server-20261003.json
- realtime-production-ops-20261003.json
- realtime-production-cache-readback-20261003.json
- realtime-production-clients-20261003.json

候选/隔离证据：realtime-linux-candidate-20261003.json、realtime-http-20261003.json、realtime-source-check-20261003T114654Z.json、realtime-brief-review-20261003.json。源码打包禁用macOS扩展属性，避免AppleDouble被SQLx误识别；生产迁移未改动。

## Azure Hermes 执行端（用户 / 2026-10-03 最新指令）

实际执行用户为服务器 `hermes`，Hermes Agent 0.21.5；Gateway 未重启。News 发布器位于 `/opt/orialis-news/current`，凭据仅在 `/etc/orialis-news/worker.env`（0640 root:hermes），本机 Codex 登录不再是服务器任务依赖。AIHot systemd timer 已启用并实测自动成功，每 5 分钟刷新。

GitHub 实际采集到日榜19条、周榜18条。真实 Hermes 日报任务保留了完整榜单，但最终输出 JSON 不完整，流水线将分析状态标记为 unavailable；第二次重跑因持续占用时间较长而停止。已加入按需加载 Paperclip 依赖、简化 JSON 输出约束及完整 JSON 对象提取恢复，19 项流水线测试通过；仍未获得 Azure Hermes 完整分析成功证据，因此 GitHub 日报与周报 systemd timer 均保持 disabled。证据：`news/evidence/realtime-azure-hermes-20261003.json`。

### Githot 来源切换（2026-10-03 15:40Z）

按用户明确要求，GitHub 热点排名来源已改为 `https://githot.dev/`（日报）及 `/weekly`（周报）；GitHub API 仍提供仓库元数据、README 与 release 信息。线上页面在本机与 Azure Hermes 服务用户下分别解析出19/18条榜单。Linux x86-64 上完成锁定依赖release编译，迁移checksum预检18/18通过。服务二进制 `/opt/oris/bin/oris-server.20261003T1532Z-githot`，SHA-256 `a647b86ba856a313c7838c94514a88ca2803910a2ec4725df0f552aa365f3b2f`；回滚目标 `/opt/oris/bin/oris-server.hermes-delivery-20261003T142020Z`。切换后 `/api/health` 为200，生产环境标识正确，服务active、重启数0。

Azure 日报 `news-github-daily-20261003-9d9d99e7`、周报 `news-github-weekly-20261003-cde385f2` 均成功发布 `source=githot.dev`；分别19/18条，前10各有10条中文摘要，brief `analysisStatus=complete`、非stale、无error。验证后已启用GitHub日报/周报timer；下次执行为北京时间10月4日18:00及10月5日18:15。AIHot五分钟timer仍启用。详见 `news/evidence/realtime-azure-hermes-20261003.json`。

## 最终状态

生产服务active、PID2387161稳定、0重启，公网health200/匿名stream401。当前日/周cache对应3d19abaf/d9c90321（自动recovery自然完成后产生的最新实际结果），中文总览complete、各9项有依据摘要，cache=result相同；没有把后续覆盖伪记成初次retry task。共观察28条已完成Dart stream200请求，只是传输证据。

上线授权继续有效；手机News需保持前台完成真实内容/自动更新核对，Mac需处理系统钥匙串授权并核对原生页面。TASK-047保持review/partial，尚不能标记客户端原生送达验收完成。

运营任务按[Paperclip协作规则](/Users/jxcz/.codex/skills/paperclip/SKILL.md)完成自身身份及run审计；[本机运营任务](http://127.0.0.1:3100/ORI/routines)。

## 2026-10-04 — 当前：Githot 原生内容直接投送

此条取代前述GitHub二次Hermes分析与README补充策略。按用户最新要求直接保留Githot卡片中文文案与每个项目的源详情分节、命令、上榜记录；不合成固定features/value/useCases或AI总览。Azure新release20261004-githot-direct-r1已发布日榜19/周榜18，37条详情全部可读，生产cache与采集publish内容精确相等。49Python和33Flutter测试通过，三个timers保持运行。客户端已改为源内容阅读；新版News arm64已覆盖安装并保留安装记录；真实详情源标题与上榜记录已截图观察可读，自动刷新和旧README实机验证仍保留原边界。证据news/evidence/githot-direct-20261004.json，决策ADR-011。
