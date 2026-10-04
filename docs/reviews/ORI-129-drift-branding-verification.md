# ORI-129 Drift 生成、升级场景与 branding 消费链核验

日期：2026-10-05（Asia/Shanghai）

## 基线与工作区

- 仓库：`/Users/jxcz/Agent Workspace/projects/orialis/worktrees/ori-129-mobile`
- 分支：`health-20261004/ORI-129`
- 专项分支：`refactor/repository-health-20261004`
- 任务开始时本地专项引用为 `e48fa78f6cfdd1c3bbd9254ea2ed26dfc11ba50b`；`origin/refactor/repository-health-20261004` 已前进到 `adafcf6e05d742957c1132a3798cd13a426da21a`。核对 e48fa78..adafcf6 的 mobile 子树无差异后，任务分支快进到专项当前头 adafcf6。报告提交后完整 SHA 见 Paperclip 交付评论。
- 初始和命令执行前工作树干净；未切换 main 或共享工作树。

## SDK、依赖与 Drift 生成

- `flutter --version`：Flutter 3.47.4 stable，framework revision `9584c6713b`；配套 Dart 3.13.3 stable。
- 锁文件解析：`build_runner 2.15.1`、`drift 2.31.0`、`drift_dev 2.31.0`。锁定的 `drift_flutter` 为 0.2.8。
- 执行 `cd mobile && flutter pub get`：退出码 0，日志结尾 `Got dependencies!`；`mobile/pubspec.lock` 无变化。
- 先列举仓库全部跟踪 Dart 生成输出，再执行：`cd mobile && dart run build_runner build --delete-conflicting-outputs`。
- 完整跟踪生成输出清单：`mobile/lib/core/database/app_database.g.dart`（唯一匹配的跟踪 `.g.dart` / `.freezed.dart` / `.mocks.dart` 输出）。Build Runner 报告 279 outputs；其中唯一跟踪输出未改变。严格检查 `git diff --exit-code -- mobile/lib/core/database/app_database.g.dart` 退出码 0；`git diff --exit-code -- mobile/pubspec.lock` 退出码 0。精确生成代码 diff：无（0 行）。
- Build Runner 退出码 0，日志：`Built with build_runner/aot in 111s; wrote 279 outputs.` 日志同时警告 `--delete-conflicting-outputs` 选项已移除并被忽略，以及 SDK 3.13.0 高于 analyzer 语言版本 3.12.0。此次生成结果干净；未来若期待该选项提供冲突清理保证，当前工具实际没有执行此选项。
- 漂移门禁建议命令：`cd mobile && dart run build_runner build --delete-conflicting-outputs && git diff --exit-code -- lib/core/database/app_database.g.dart`。干净基线退出码 0。以临时追加注释制造的负例中，`git diff --exit-code -- mobile/lib/core/database/app_database.g.dart` 退出码 1；原文件字节恢复后退出码 0。若扩展为全部跟踪生成输出，应先从 `git ls-files` 枚举完整清单，不要猜路径。

## 升级与语义测试映射

命令 `cd mobile && flutter test test/project_milestone_migration_test.dart test/subevent_migration_test.dart test/outbox_store_test.dart` 退出码 0，共 14 tests passed：

| 场景 | 现有覆盖 | 结果 |
| --- | --- | --- |
| schema v5 升至 v10，旧 Task/Schedule 字段保留，Outbox 创建 | `outbox_store_test.dart`: `v5 fixture migrates legacy Task/Schedule data and creates Outbox` | passed |
| schema v6 升至 v10，旧数据、Outbox、同步元数据和聊天兼容表保留 | `project_milestone_migration_test.dart`: `v6 upgrades to v10 without changing existing data or outbox` | passed |
| v6 Task 关联字段空值、CalendarEvent important 默认值、升级后关联写入 | `subevent_migration_test.dart`: `v6 data migrates to v10 with empty task links and unimportant events` | passed |
| v7 项目字段往返、milestone 稳定排序 | `project_milestone_migration_test.dart`: `v7 fields round-trip and active milestones have stable ordering` | passed |
| Outbox 重启恢复、in-flight 不可变、重试复用 mutation/payload、事务失败无 entity-only 写入、ack 后只 rebase 后续未发送项 | `outbox_store_test.dart` 其余相关用例 | passed |

命令 `cd mobile && flutter test test/desktop_account_isolation_test.dart test/sync_state_test.dart` 退出码 0，共 6 tests passed，覆盖 account/server 文件隔离、cursor/outbox 保留、匿名模式不发请求/不丢 pending mutations、remote state 不覆盖 queued mutation。

覆盖边界：未发现 v1-v4 专属 fixture 升级测试；未执行移动设备/ADB、生产数据库、端到端服务或外部写入测试。当前 schemaVersion 为 10。本任务没有改 Drift schema、账号分区、同步事务、锁文件或服务端 migration 文件；历史 SQL migration checksum 未重算，因为此次没有服务端 migration 变更。

## Branding 源、生成入口与消费者

- `mobile/assets/branding/README.md` 将参考源记录为 user / 2026-10-02 图片，原图保存在 `source-reference.png`。README 描述两个 1024×1024 RGBA master 为去除海报文字/外部背景后的提取图；没有声明开放许可证或单独授权文本，本报告不据此推断第三方开放许可。
- `mobile/pubspec.yaml` 显式打包 `assets/branding/orialis-schedule.png` 与 `assets/branding/orialis-news.png`；不打包 `source-reference.png` 或 README。
- 主应用消费者：`profile_page.dart` 使用 schedule master；Android 默认 manifest placeholder 选择 `@mipmap/ic_launcher`；macOS `AppIcon` catalog 指向由 schedule master 生成的蓝色 Orialis 图标。
- News 消费者：`news_app.dart` 使用 news master；Android `newsApp=true` 选择 `@mipmap/ic_launcher_news`。News 页面可消费暖色 News artwork；macOS 当前 AppIcon 仍是 schedule 蓝色身份，没有单独 News macOS target 证据。
- 生成入口 `mobile/tool/update_brand_icons.sh`：macOS `sips`，从两个 master 生成 Android 五档 mipmap（每个 master 五张，共 10 PNG）和从 schedule master 生成 macOS 16、32、64、128、256、512、1024 七档图标。脚本未固定 sips/macOS 版本；本机 `sips` 来自 macOS 27.0.1（build 26A434）。Android Gradle 切换点为 `mobile/android/app/build.gradle.kts`。
- 跟踪 branding 树共 22 个文件：README 1、输入 PNG 3（两个 master + source reference）、Android 衍生 PNG 10、macOS 衍生 PNG 7、macOS Contents.json 1。所有必要生成源码、master、平台资源均保留；未提出删除。
- 此处为源码/配置消费链检查，没有实际执行 APK 或 macOS app 打包；不声称运行包内资源验收通过。

## 产物与分类快照

基线 adafcf6 工作树：763 个跟踪文件；187 个跟踪 Dart 文件，其中 1 个生成 Dart 输出（`app_database.g.dart`）；branding 树 22 个跟踪文件。`git rev-list --objects --all` 输出 2,467 个跨 refs 对象路径项，作为历史对象快照，不是唯一对象去重计数。运行命令后本地忽略缓存为 `mobile/.dart_tool` 约 62 MB、`mobile/build` 约 54 MB；二者不是发布源资产，不计入 Git diff。其余跟踪文件包含人工源码、配置、测试、迁移、平台资产及文档；此计数不把每个非生成文件都误标为人工源码。

## 回滚

本分支仅增加本核验报告；没有产品代码、生成文件、锁、迁移、资产或 workflow 改动。回滚交付只需反向应用报告提交，不涉及数据库/生成资产/部署回滚。

## 补充证据（2026-10-05，正式审核退回后最小重跑）

为满足正式审核的独立复核要求，上一轮命令日志因未保存在工作树而无法回溯；现已在同一隔离 worktree 重跑并保存原始 stdout/stderr、命令行与显式退出码。日志随 PR 提交于 `docs/reviews/ORI-129-evidence/`：

- `toolchain-and-pub-get.log`：Flutter/Dart 实际版本与 `flutter pub get`，退出码见文件。
- `generation.log`：受跟踪生成输出枚举、build_runner 完整输出和生成输出/锁 diff 门禁。此轮 build_runner 读取 560 inputs / 280 combining inputs，`wrote 0 outputs`，退出码 0；唯一跟踪生成输出仍是 `mobile/lib/core/database/app_database.g.dart`，生成输出及锁 diff exit 0。较早首次运行 `wrote 279 outputs` 的摘要保持在上文，两者分别是首跑与稳定后的重跑结果。
- `migration-outbox-tests.log`：迁移/项目 milestone/subevent/outbox 定向测试原始输出，14 tests passed，exit 0。
- `account-sync-tests.log`：账户隔离与 sync state 定向测试原始输出，6 tests passed，exit 0。
- `drift-gate-negative.log`：无差异正例 exit 0、临时注释制造漂移负例 exit 1、原字节恢复后 exit 0。负例已恢复，未留生成文件改动。

本次按评审意见明确标记为 **skipped**：

- **v1–v4 专属升级 fixture/test：skipped**（仓库中未发现对应专属 fixture；本任务未新增 fixture）。已有覆盖从 v5/v6 升至 v10，见前述映射表。
- **APK 与 macOS app 实际打包/包内资源检查：skipped**（本任务仅核验源码、Gradle/manifest、pubspec 和图标资源消费链；没有运行平台打包，也未使用 ADB）。

GitHub PR checks 的本任务独立查询曾返回 401；因此不把 PR 页面可能显示的 job 状态计为本轮独立通过证据。父任务可按 PR #7 的链接及具体 head SHA 自行读取当时检查快照。生产库、服务端迁移 checksum、设备、ADB 与外部写入仍未执行。
