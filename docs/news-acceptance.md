# Orialis 资讯 V0.1 验收记录

本次由总管整合客户端、后端、运营三个 Luna 工作组。批准范围为用户的六阶段路线图，权威源码位于现有 Orialis repo。**完整 V0.1 暂未通过生产与自动调度验收。** 本记录将代码、隔离环境验证、真实来源和生产运行分开记录。

## 实现边界

- Android 保留独立 `main_news.dart` 入口与应用身份。用户最新明确电脑端只有一个 Orialis App，AI Hot、GitHub、Project 平级接入现有 `main_desktop.dart`，无“资讯”菜单和桌面内层分类导航，共用桌面账户、服务和外观；不交付独立 macOS 资讯产品。两端复用现有 Lumina 组件、主题和 tokens。
- AIHOT 直接读取官方 OpenAPI 的热点、精选、日报、周报、月报和事件详情。相同 story 每轮只抓一次，digest/status/latest 复用到热点卡片；没有额外 LLM。上游未提供热度或趋势时显示缺失，不编造曲线。
- GitHub 日榜和周榜独立抓取官方 Trending，读取官方 metadata/README/topics/release。分析限制在本轮事实，每仓库回答用途、功能、价值与场景。故障保留基础榜单。
- 所有读取需 Session；缓存按服务地址与会话隔离。Projects 按用户隔离；发布方使用独立、固定绑定用户的 publisher 身份。
- 项目秘书协议严格校验字段与日期，只接收报告。用户确认目前没有秘书报告，正式页面显示空状态；测试报告不作为真实项目进展。
- 审计保存 taskId、状态、起止时间、来源、结果和错误；发布前持久化原始请求，响应丢失后用同一请求重试。
- Paperclip 已在正确 Orialis 公司补齐运营部负责人、GitHub情报组与项目汇报组，持久创建并独立读回四条 disabled 调度；AIHOT 专用纯 process Agent 已创建并验证命令、目录、权限与关闭的 heartbeat。使用真实 Routines / schedule trigger API。AIHOT 为纯 collector process，不调用 Codex。Github/Projects 使用可替换 Runner。

## 已有验证证据

| 层级 | 结果 | 证据与限制 |
|---|---|---|
| 客户端自动检查 | 定向 analyze 无问题；23 个客户端专项通过 | desktop flow 1、键盘导航 12、Android资讯 10；平级三入口与无资讯菜单，Cmd1–8，900px/560px，仓库详情返回同分支；账号切换、外链限制和原报告降级 |
| 新闻后端 | 12 个专项测试通过 | 请求指纹绑定动作/来源/完整 payload；失败重试、鉴权、隔离、严格日期；GitHub 新旧结果兼容和总览投影已测 |
| 来源采集 | 8 个测试通过；实时读取 10 热点、10 详情、10 digest、0 详情错误 | 官方源；单 story 读取复用与失败保留基础字段 |
| 真实 HTTP | 12 项端到端检查通过 | `news/evidence/http-integration.json`；AIHOT 10 热点、100 精选、三类报告，GitHub 日/周榜各17条，鉴权、幂等、项目报告跨用户隔离；Projects 数据与总览投影校验正文为明确测试 fixture，真实 AI 输出另验 |
| 本地服务器 | 优化构建成功 | 本机 Mach-O，不是 Linux 可部署产物 |
| 全服务端 | 最新 71 通过 / 2 失败 | 两项并发 Node 配对测试失败，资讯专项通过；以最新整合复跑结果更新，不能据此宣称整体可发布 |
| 流水线 | 15 项测试通过 | 发布 outbox 原请求重试、空报告无模型/无投送、分析越界整份降级、完整基础榜单保留 |
| Android | 独立 debug APK 构建成功 | `-PnewsApp=true`；尚未真机验收、未正式签名 |
| Nagi Runner | SSH、现有登录、真实 probe、日/周榜前十个仓库简报与总览成功 | 可复用一次性 SSH reverse loopback Runner 已完成真实探针；真实结构化 JSON 与17条排名/前10个分析核对；`news/evidence/github-daily-brief-2026-10-02.json`、`news/evidence/nagi-runner-probe-2026-10-02.json`，不改凭据/全局配置；实际调度环境与 publisher 联调尚未完成 |

真实 Nagi 日榜与周榜简报已发布到自有隔离 loopback API：每榜17条排名、前10个仓库简报，GET 总览正文与原 Nagi 输出精确一致。证据 `news/evidence/real-runner-api-readback.json`。此验证不包括 Paperclip 调度，独立周榜也完成真实 Nagi 分析与隔离 API 正文精确读回。

可复跑 HTTP 验证：先构建 `target/release/orialis-server`，执行 `python3 scripts/verify-news-http.py`。脚本仅启动隔离 loopback 服务和临时数据库，读取真实公开源，不使用生产地址或凭据。

## 尚需验收的门

1. Paperclip 当前健康恢复，组织、AIHOT 专用纯 process Agent 与四条 disabled 调度已创建并由总管独立读回，见 `news/evidence/paperclip-manager-readback.json`；仍须验证实际任务执行后再启用。
2. Nagi 一次性 SSH Runner 已真实探针验证；还须完成实际任务环境与 publisher 配置，完成一次 Paperclip → Nagi → News API → App 的真实投送；临时 probe 不能代替自动运行。
3. Linux 构建、现有数据库迁移预检、回滚包、健康验证，之后才进入生产发布。当前未修改生产服务。
4. 用户提供第一份真实秘书报告后，完成真实接收/总报/原报告故障降级验收。当前接收协议可测，真实内容不存在。
5. Android 真机与正式签名仍待验证；统一 Orialis macOS 构建、签名与隔离账号原生页面已完成。

现有 Node、Devices、Wear、Lumina 并行改动均保留。未推送代码、未合并、未创建用户通知或额外云资源。

## 最终产物与原生界面

统一 macOS 包：[Orialis-macos.zip](../desktop/dist/20261002T152001Z-news-primary-navigation/Orialis-macos.zip)，正常产品入口 `lib/main_desktop.dart`，bundle ID `top.jxcz.orialis`；arm64/x86_64，原生成签名通过 strict 校验。包旁附 SHA256SUMS 与 build-evidence.json。测试会话凭据不在交付应用中。

Android 最新 debug 包：[Orialis-News-android-debug.apk](../news/dist/20261002T152822Z/Orialis-News-android-debug.apk)，身份 `top.jxcz.orialis.news`、0.1.0、minSDK24 / target36；252 构建任务成功。该包不是正式签名发行版，未做真机验收。

总管通过原生界面观察验证平级八项导航（今日/任务/项目/日历/AI Hot/GitHub/Project/我的）、无“资讯”总菜单及桌面分类二级导航。AI Hot Top10、事件摘要、时间线、来源按钮；真实 Nagi GitHub 日/周总览、仓库详情和返回同一周榜；Project 真实空状态与共用主账户均已核对。内容改为全宽纵向阅读流，修复机械配成两列产生的大片空白。对应证据 `news/evidence/unified-desktop-native.json`。

原生数据核对在临时验收副本中进行，使用自有隔离 loopback 服务和固定测试账号；交付正常包不注入该账号、地址或 token。专项测试覆盖900/860/560px导航与阅读布局。临时应用/服务已关闭，实际生产账户和服务器未变更。

客户端最终复核：23项专项（桌面流1、键盘12、资讯10）通过；单列修复后重跑受影响11项通过，定向 analyze 无问题。
