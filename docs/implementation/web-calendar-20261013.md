# Orialis Web 与复杂日程编辑 — 2026-10-13

## 交付状态

已实现独立 `web/` 浏览器客户端，复用现有 Orialis 服务端；本地构建、日程单元测试与真实浏览器/独立服务端接口验收通过。未进行线上发布、用户人工验收或真实 Agent 回复验收。

用户确认本轮日程范围：周/月视图、跨天与全天、提醒、冲突提示、按星期批量生成重复日程。另提供列表视图、日/月重复、间隔、数量和截止条件、复制。

源代码基线：`9e6c44a370571ffc3ffa22e8a277aecf66dab09d`。实现分支：`codex/orialis-web-calendar`，本轮交付为工作区源码，未提交或推送。执行目录：`/Users/jxcz/Agent Workspace/projects/orialis/repo`；Web 检查目录为其 `web/` 子目录。

## 复用与边界

- `web/src/api.ts` 复用 Session 认证、完整分页、现有 CRUD，PATCH 使用服务端 `baseVersion`。
- `web/src/calendar.ts` 负责纯日期规则；`main.ts` 负责登录、主导航、今天、日历与日程编辑；`workspace.ts` 负责任务、项目、文本聊天。
- 采用现有 Lumina light tokens 的颜色。布局是固定侧栏、宽屏七列日历、独立编辑对话框；窄屏顶部导航，日历内部横向滚动。
- 重复操作展开为最多 100 条独立日程，沿用 `/api/v1/schedules`。无新数据库结构，不宣称支持重复系列、系列例外或整组编辑。
- 写入 UTC、按浏览器本地时区显示；全天结束日期含当天、存储排他次日零点。读取全部分页再做区间重叠过滤，包含从窗口外开始的跨天日程。
- 当前提醒设置只同步给已有客户端，Web 无后台通知；聊天回复依赖已有 Agent 在线，Web 手动刷新。
- 批次中断保留固定客户端 ID，对账后继续剩余项；非整体原子事务。409 提示冲突且保留编辑器草稿，刷新后由用户重新编辑。

## 本地验证

所有下列已执行检查的退出码为 0（故障注入的 HTTP 409/503 是预期测试响应）。

| 检查 | 真实命令 / 结果 |
| --- | --- |
| 服务端编译 | 仓库根目录 `cargo build -p orialis-server`，完成 dev 构建；未修改 Rust 源码。 |
| Web 构建 | `npm run build`，TypeScript 严格检查和 Vite 生产构建通过。 |
| 日程规则 | `npm test`，10 项通过、0 失败、0 跳过。涵盖日/周/月、月末跳过、夏令时、跨天、全天半开区间、零时长历史数据、非法输入。 |
| 格式检查 | `git diff --check -- README.md web docs/implementation/web-calendar-20261013.md`。 |
| 浏览器 | Playwright CLI + 本机 Microsoft Edge；Vite `127.0.0.1:4177`，服务端 `127.0.0.1:18443`，数据库通过 `mktemp` 在 `/tmp/orialis-web-acceptance.*` 独立创建，未访问生产账户数据。 |

浏览器实际操作及回读：

1. 新建测试账号、登录，Session 刷新恢复。
2. 每周二/四创建 4 条重复日程，提醒 30 分钟；刷新和 API 回读确认数量、星期和提醒。
3. 修改开始/结束后切换全天，保持新日期；跨天工作坊保存、复制，全天/重要/提醒/含结束日期均保留。
4. 另一个请求先更新相同日程，再提交旧版本，收到真实 409；保留本地输入，关闭并刷新后显示另一设备修改。
5. 第二个 POST 注入 503，界面显示已确认 1/3；再次保存并查询，最终恰好 3 条，无重复。
6. 直接编辑日程并保存成功，月视图 42 格、列表 7 天切换通过。
7. 任务创建与标记完成、项目创建、新会话创建、文本消息发送与刷新回读通过；未模拟或宣称真实助手回复。
8. 390px 窄屏检查页面 `scrollWidth === innerWidth`；1440px 桌面截图检查。

浏览器操作脚本、快照与截图在本地被忽略的 `web/output/playwright/`、`web/.playwright-cli/`，不含生产凭证。主要截图：`calendar-week.png`、`calendar-month.png`、`calendar-mobile.png`、`chat-mobile.png`。

## 协调与后续

本任务按 coder 的 assigned-task-paths 实施，角色路由返回 `routed / codex`。授权修改边界为新增 `web/**`、本记录及 README 索引。日程规则与其他业务页由独立子任务分工，主执行者负责整合和浏览器验收。

启动检查发现历史 `project.yaml`、`state.md`、`roadmap.md`、`memory/summary.md` 不存在，未伪造旧任务或重建历史状态；本文件记录本轮实际范围与状态。工作中发现同时出现的 `mobile/**` 与 dark-mode 说明变更属于其他工作，本轮未改动或提交它们。

生产部署使用 `web/dist/` 与同源 `/api` 反向代理（`web/nginx.example.conf`）。还需单独执行生产发布与真实账户/设备验收。共享记忆读取超时，本轮事实来源为源码及上述执行证据。
