# 手机界面性能降耗 · 2026-10-24

本次用户范围：优化 Orialis 手机界面的性能消耗。工作树为 `repo-latest`，
分支 `codex/orialis-optimize-20261024`，基线 `719f51c`。
本地实现和自动验证完成；尚未打包、安装到手机或测量真机功耗、内存和帧率。

## 已确认开销与改动

- `packages/lumina_ui/lib/src/lumina_patterns.dart`：`LuminaReveal` 原本只隐藏
  折叠内容，其内部 ticker 仍持续请求帧。现在退出动画结束后通过 `TickerMode`
  暂停内部动画，展开后恢复；保留子控件 State，继承祖先的禁用状态。
- `mobile/lib/pages/today/today_page.dart`：原先常驻的分钟定时器在切换页签后
  仍重建“今日”。现在仅在页面可见且应用前台时运行；离页或后台取消，返回时
  立即更新显示并恢复计时。原有任务和日期范围数据流继续复用。
- `mobile/lib/news/news_pages.dart`：资讯页原先仅按应用前后台管理请求，未选中
  的页签仍保持 watch、30 秒轮询和重连。现在只在前台且页签可见时订阅；隐藏时
  取消实际订阅，仓库随之停止轮询和重连。返回时恢复并保留已显示内容；隐藏时
  不触发手动或刷新 scope 的请求，账号切换仍清空旧结果。
- `mobile/lib/pages/projects/projects_page.dart`：复用项目、里程碑和关联任务的
  数据流，减少选择项目及界面重建时的重复订阅。更换 repository 后清空缓存并
  重建项目 StreamBuilder，避免旧 snapshot 触发旧项目的数据流。Drift 查询流
  支持广播，同一里程碑流可供摘要和详情同时监听。

## 验证

共 77 项相关自动测试通过：

- Lumina UI 23 项：`lumina_reveal_test.dart`、`lumina_components_test.dart`。
- 手机端 54 项：`today_page_performance_test.dart`、`projects_stream_cache_test.dart`、
  `news_realtime_test.dart`、`news_app_test.dart`、`lumina_app_flow_test.dart`、
  `lumina_page_edges_test.dart`、`desktop_app_flow_test.dart`、
  `desktop_projects_layout_test.dart`、`order_gesture_test.dart`。

新增回归直接验证：折叠后 ticker 不再推进且不再持续安排帧、子 State 保留；
隐藏或后台三分钟内“今日”没有分钟计时导致的页面重建，恢复后重新计时；隐藏
资讯页不启动订阅、离页取消、恢复前台但仍隐藏时不启动、回页恢复、缓存保留，
以及可见时的手动刷新和 scope 刷新；项目选择重建复用数据流和 repository
切换后的新库数据。项目测试使用两个独立内存库时 Drift 输出多实例提醒，测试
通过且没有 Flutter 异常。

修改源码及新增/修改测试的定向静态分析通过；`git diff --check` 通过。
现有导航、事件创建、日历切换、项目里程碑、拖动排序和返回操作回归通过。
上述测试证明对应冗余活动被消除，不代表真机节电百分比或帧率提升实测。

## 范围与项目状态

本次按 `coder` 的 assigned-task-paths 边界实施，仅涉及上述四处实现与对应
测试和本记录。通过现有工作区脚本的角色路由预览确认 `status=routed`、执行器
为 `codex`。本地缺少 Orialis 外层 `project.yaml`、`state.md`、`roadmap.md`、
`memory/summary.md`、`memory.db` 和任务/项目 Role 目录，未重建或推断全局任务
状态；本记录承载本次实现及验收状态。

共享记忆已按 `aw-orialis` 查询。工作树中的主题切换、聊天、Hermes 和生成文件
等已有修改保持原样，不归属本次性能任务；本次没有提交、推送或发布。
