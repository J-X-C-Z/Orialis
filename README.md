# Orialis

Orialis 是包含 Rust 服务端、Flutter Android/macOS 客户端、穿戴端实验、Web 原型、设计系统和外部 Agent/新闻集成的 monorepo。产品代码与各子项目状态以本文链接的当前入口为准；历史里程碑与验收记录只证明其标注日期、快照和范围，不代表所有当前功能都已验收。

**索引核对：2026-10-04。** 来源为当前工作区目录/入口、包清单和 [CI workflow](.github/workflows/ci.yml)；本文列出可复现的检查入口，不声称本轮已运行每个子项目构建或完成用户验收。个人指派信息不在仓库内维护，责任人按路径边界说明，具体当前 assignee 以 Paperclip 事项为准。

## 范围与部署边界

- **生产服务端**：`orialis-server/` + `orialis-core/`，监听地址、数据库与反向代理由 [`docs/server-architecture.md`](docs/server-architecture.md) 和 [`deploy/`](deploy/) 配置约束。服务器部署只部署服务端，不会部署 Flutter、Vela、Web 原型或本地工具。
- **客户端和交付物**：Flutter Android 与 macOS 共享应用源码但使用不同入口；News Android 使用独立入口。macOS/Android 本地构建不是服务端部署步骤。
- **整个 monorepo**：还包含 Vela 手环端、未发布的官网原型、Lumina UI/tokens/web、Hermes 插件、Codex gateway、Python SDK 和 News 数据流水线。各目录的源代码、脚本、构建产物与运行证据用途不同；目前不把 `news/` 当作产品源码目录，也不把工具型 `desktop/` 因源码少而删除。
- **不代表已验收**：工作区存在实现或 CI 命令不等同于设备、生产部署或用户验收。各平台剩余验证见下表及链接文档；验收状态以带日期和范围的证据为准。

## 交付物索引

| 交付物 / 入口 | 当前状态、范围与依赖 | 真实检查或运行命令 | 契约 / 代码责任边界 / 未完成验证 |
| --- | --- | --- | --- |
| Rust 核心与服务端：`orialis-core/`、`orialis-server/` | 实现位于 workspace；CI 有格式和测试 job。Axum、SQLx、SQLite | `cargo fmt --all -- --check`；`cargo test --workspace` | [`docs/server-architecture.md`](docs/server-architecture.md)、[`docs/api-v1.md`](docs/api-v1.md)、[`docs/sync.md`](docs/sync.md)。服务端负责 SQL row、HTTP DTO、事务与同步事件；生产部署看 [`deploy/`](deploy/)。设备与生产运行验收单独记录。 |
| Flutter 主客户端：`mobile/lib/main.dart` | Android 客户端实现；CI 有 analyze/test job。本地 Drift、HTTP/Sync、共享 `packages/lumina_ui` | `cd mobile && flutter pub get && flutter analyze --no-fatal-infos && flutter test` | [`mobile/README.md`](mobile/README.md)、[`docs/mobile-architecture.md`](docs/mobile-architecture.md)。本地数据库/同步由移动端仓储与 SyncEngine 负责；真机验收状态看设备交付记录。 |
| Flutter macOS 桌面入口：`mobile/lib/main_desktop.dart` | 同一 Orialis 应用的独立 Dart 启动入口，不是独立 News 产品；应用界面和业务代码仍在 `mobile/`，共享 Flutter、Drift、Lumina | `cd mobile && flutter build macos --debug --target lib/main_desktop.dart` | [`mobile/README.md`](mobile/README.md)、[`docs/desktop-platform-baseline.md`](docs/desktop-platform-baseline.md)、[`desktop/local-release.md`](desktop/local-release.md)。CI 有 macOS debug 构建；签名发布、实机及最终桌面验收需看更新的交付证据。 |
| macOS 本地构建工具：`desktop/` | 本地工具与交付说明，不是另一个客户端源码目录，也不是服务器部署内容 | 环境准备：`source desktop/prepare-macos-toolchain.sh`；产品发布包装器的检查方式见 [`desktop/local-release.md`](desktop/local-release.md) | 需 macOS、Xcode、CocoaPods、Flutter 与 run-owned 可写 scratch；工具链诊断步骤见 [`desktop/macos-toolchain.md`](desktop/macos-toolchain.md)。包装器文档中的 `<desktop-entry>` 是占位符；目前入口 `mobile/lib/main_desktop.dart` 可用于 CI debug 构建，但发布包装器还要求产品负责人确认目标入口及其非聊天隔离行为。该入口关系和工具前置条件不代表已完成签名发布或用户验收。 |
| News Android：`mobile/lib/main_news.dart` | Android 独立应用入口；复用移动端基础与新闻 API；验收需看带日期的交付证据 | `./mobile/build_news_android.sh`；新闻逻辑：`python3 -m pytest -q integrations/news/tests` | [`mobile/NEWS_APP.md`](mobile/NEWS_APP.md)、[`docs/news-acceptance.md`](docs/news-acceptance.md)、[`docs/news-operations.md`](docs/news-operations.md)。根目录 `news/` 用于运行数据和证据，不是源码搬迁目标。 |
| Vela 手环端：`band/vela/` | Vela AIoT Toolkit 项目；单独记录模拟器/设备状态 | `cd band/vela && npm test && npm run build` | [`band/vela/README.md`](band/vela/README.md)。该目录维护 Vela 界面/诊断；真机与模拟器支持情况按 README 的验证记录，不推断为通用 Flutter 平台支持。 |
| 官网原型：`website/` | 独立 Vite + TypeScript 本地原型，未公开发布 | `cd website && npm run build` | [`website/README.md`](website/README.md)。演示不写入账户、日历或服务端；不是已上线官网或 Orialis Web 客户端。 |
| Lumina Flutter UI：`packages/lumina_ui/` | Flutter/Dart 包，仓库内 path dependency，未发布 pub.dev | `cd packages/lumina_ui && flutter test && flutter analyze lib test` | [`packages/lumina_ui/README.md`](packages/lumina_ui/README.md)；控件实现和包级验证由该包维护。 |
| Lumina tokens：`packages/lumina_tokens/` | 跨平台源数据；生成 Flutter 映射 | `python3 packages/lumina_tokens/generate_flutter.py --check` | [`packages/lumina_tokens/README.md`](packages/lumina_tokens/README.md)。改动从 JSON 源开始，并核对生成文件。 |
| Lumina Web：`packages/lumina_web/` | React + TypeScript 组件和展示页 | `cd packages/lumina_web && npm run typecheck && npm run build` | [`packages/lumina_web/README.md`](packages/lumina_web/README.md)。这是组件库/展示页，不是 Web 产品客户端。 |
| Hermes Orialis 插件：`integrations/hermes/orialis/` | Python 插件适配器；连接服务端 Agent Gateway | `python3 scripts/validate-contracts.py`；`bash scripts/validate-hermes-plugin.sh` | [`integrations/hermes/orialis/README.md`](integrations/hermes/orialis/README.md)、[`protocol/agent-gateway/README.md`](protocol/agent-gateway/README.md)。插件负责 Hermes 侧协议适配；完整运行时验证需可用的 Hermes 环境。 |
| Codex Gateway：`integrations/codex_gateway/` | Codex CLI / 新闻发布等本地集成 | `python3 -m unittest integrations.codex_gateway.test_gateway` | [`integrations/codex_gateway/README.md`](integrations/codex_gateway/README.md)。这是本机集成边界，不属于生产服务进程。 |
| Python SDK：`integrations/orialis_sdk/` | Python HTTP 与多设备调用库 | `python3 -m pytest -q integrations/orialis_sdk/tests` | [`integrations/orialis_sdk/README.md`](integrations/orialis_sdk/README.md)、[`protocol/contracts/README.md`](protocol/contracts/README.md)。SDK 映射 HTTP 契约，不拥有数据库 schema。 |
| News 流水线：`integrations/news/` | Python 采集、处理、发布及任务记录；`news/` 保存运行数据/证据 | `python3 -m pytest -q integrations/news/tests`；源数据工具：`python3 scripts/news_sources.py --help` | [`docs/news-operations.md`](docs/news-operations.md)。调度器、服务端发布身份与实时发布均有独立前置条件；历史运行记录不证明当前发布链路可用。 |

目录职责是代码边界，不表示当前员工/Agent 指派；仓库没有可核实的个人 owner 清单，因此不猜测个人负责人。任务负责人及复核人以 Paperclip 对应事项为准；本次仓库整改由 [ORI-103](/ORI/issues/ORI-103) 跟踪。

## 当前架构约束

[`docs/architecture.md`](docs/architecture.md) 是当前架构索引。重点约束如下，细节只在链接的契约文档维护：

- Task 是带截止信息的行动项，Schedule 是明确起止时间的日程；Today 只聚合查询。`calendar_events` 表、`CalendarEvent` API 兼容类型和 `calendar_event` 同步类型仍保留为兼容别名。
- SQL rows、HTTP DTO、共享领域值、Drift 记录和 wire maps 属于不同边界；不为统一命名直接跨层改名。
- 同步写入与事件追加必须同一服务端事务提交；移动端实体写入与 outbox 初始记录须同一 Drift 事务。`version`、`baseVersion`、`localRevision`、`cursor`、Agent `seq` 含义不同，冲突不静默覆盖。
- 当前唯一机器可读跨端契约目录是 [`protocol/contracts/`](protocol/contracts/README.md)；HTTP 行为看 [`docs/api-v1.md`](docs/api-v1.md)，同步看 [`docs/sync.md`](docs/sync.md)，Agent Gateway 看 [`protocol/agent-gateway/README.md`](protocol/agent-gateway/README.md)。

## 本地服务端运行与部署

需要 Rust stable 和 SQLite：

```sh
cargo run -p orialis-server
curl http://127.0.0.1:18443/api/health
curl http://127.0.0.1:18443/api/v1/meta
```

本地数据库与监听设置可通过 `ORIALIS_HOST`、`ORIALIS_PORT`、`ORIALIS_ENV`、`ORIALIS_DATABASE_URL` 配置。生产服务使用 `deploy/orialis.service`、`deploy/orialis.env.example` 和 Nginx 模板；真实凭证只从部署环境注入，示例文件不放密钥。部署边界与备份恢复说明见 [`docs/server-architecture.md`](docs/server-architecture.md) 和 [`docs/backup-restore.md`](docs/backup-restore.md)。

## 合同与 CI

跨端 JSON Schema、fixtures 与注册表见 [`protocol/contracts/`](protocol/contracts/README.md)。CI 的实际检查入口在 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)：Rust 格式/测试、Flutter Android analyze/test、macOS debug build、Hermes 基础契约检查及 `git diff --check`。Clippy 当前标注为允许失败的持续整改项，完整设备/生产验收不由该 CI 代替。
