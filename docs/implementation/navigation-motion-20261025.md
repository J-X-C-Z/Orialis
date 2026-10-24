# 左右切换与聊天进入转场 · 2026-10-25

用户反馈左右切换卡顿、进入聊天动画不流畅。本次在 `repo-latest`、
`codex/orialis-optimize-20261024`（HEAD `719f51c`）修改公共
`LuminaBranchTransition`，调用方包括手机和桌面 shell、聊天列表/会话详情。
验收目标：减少整页转场合成与逐帧外壳更新，保留页面状态、输入和返回行为。

## 实现

原实现为每个分支分别维护透明度和位置 spring；转场期间进出整页同时绘制，
合并的 AnimatedBuilder 每帧重建全部分支包装。现在改为单个 220ms controller，
使用现有 `luminaEaseOut` 与 SlideTransition 做 2.5% 页宽的短距离进入；
普通模式透明度恒为 1，旧分支立即 Offstage，仅绘制目标页。
Stack/分支外壳不再由逐帧 builder 重建，位移只更新绘制。
快速切换从当前偏移重新趋近零；保留分支 State、TickerMode、焦点与语义隔离。
减少动态模式保留 140ms、.96 → 1 的轻淡入，无位移。

本次未修改聊天数据加载、目标缓存或消息处理；这些代码的冷启动成本没有测量。

## 验证结果

- `packages/lumina_ui`：`lumina_completion_test.dart`、
  `lumina_components_test.dart`，37 项通过。
- 新增转场测试验证动画推进期间无额外页面 layout、目标以外分支不绘制、
  普通模式 opacity 恒 1、220ms 后不再安排帧，以及返回时复用原 RenderObject。
- `mobile`：`shell_keyboard_test.dart`、`lumina_app_flow_test.dart`、
  `lumina_chat_flow_test.dart`、`desktop_app_flow_test.dart`，9 项通过。
- 改动源码及测试定向静态分析无问题；本次两文件 `git diff --check` 通过。
  全工作树检查仍报告原有 `mobile/pubspec.lock` CRLF 空白，不属于本次改动。
- 独立只读复核没有发现需要修改的问题。

`flutter devices` 仅检测到 macOS，无手机。本次验证证明转场结构和功能行为，
没有真机 Profile 帧率、功耗或手感验收；未打包、安装、提交、推送或发布。

## 范围与状态

按用户明确的动画优化请求，以 `coder` 的 assigned-task-paths 边界工作，
范围为公共转场实现、对应测试及本记录。角色路由以 `--no-record` 预览确认
`status=routed`、执行器 `codex`；模型推荐只是预览结果，不代表切换了主会话模型。
外层项目缺少 project.yaml、state.md、roadmap.md、memory/summary.md、memory.db
及项目 tasks/roles，未伪造全局任务状态；本记录承载当前验收进展。
已有未提交的聊天、主题、服务器等工作保留，completion 测试原有修改也保留。
共享记忆已显式查询 `aw-orialis`；本次结论按实现和自动验证范围记录。
