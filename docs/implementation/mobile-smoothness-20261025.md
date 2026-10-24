# 手机端长回复与事件列表流畅度优化 · 2026-10-25

用户要求：落实两项性能优化，保留现有格式、动画和拖动排序。
工作树 `repo-latest`，分支 `codex/orialis-optimize-20261024`，基线 `719f51c`。
本地实现与自动回归完成；未打包、安装、提交、推送或发布，未做真机帧率/功耗测量。

## 长回复

`mobile/lib/features/chat/presentation/safe_markdown.dart` 继续实时呈现 Markdown，
沿用原解析规则。仅在代码围栏外的空行处分段，稳定前缀复用解析块与 Widget 实例，
变化尾段重新解析；相同 source 直接返回已有结果，跨实例的段缓存仍受 48 项与
8000 字符阈值约束。没有增加依赖，也没有改成等待回复完成才显示富文本。

`intelligence_markdown_test.dart` 逐字符比较增量结果与原全量解析结果，覆盖
CRLF、表格、代码围栏、围栏内空行、未闭合围栏、引用、有序列表和 `orialis-ui`。
千段稳定段落加尾段的回归确认：追加文字只新增一次段落解析，稳定块保持相同
对象；相同输入零次新增解析。`response_ui_test.dart` 确认追加文字后交互卡片的
标签页与清单状态保留。

这里减少的是 Markdown 解析与稳定内容的重复构建；新输入仍需扫描段落边界，
单个持续增长的未闭合大块仍需更新，不能据此声称所有长文本处理都变成常数成本。

## 事件列表

`events_page.dart` 在一次遍历中完成筛选与象限分组。手机布局改用
`CustomScrollView` 和 `TaskQuadrantSliver`，桌面原有两列布局保留。
卡片使用现有 `LuminaCardDecoration`、调色板、标题、字号和内边距。

`LuminaCompletionList.sliver` 复用已有完成/撤销/保存失败处理及材质动画，
按稳定键懒构建行。只保留仍挂载或正在完成/退出的行，不缓存所有曾滚动经过的
Widget。最后一行退出平稳交接空态，快速筛选反向保留行状态。
入场时保留布局占位，并继续按原进度绘制开口、透明度和材质，避免成批零高度
新行使懒列表在同一帧构建全部内容；未出现在视口内的新行不补播入场动画。

原 `NewsSliverReveal` 提升为共享 `LuminaSliverReveal`，资讯入口保留兼容别名，
事件卡片沿用同一时长/曲线、extent、opacity 和快速反向逻辑。初始折叠不构建
任务行；曾展开的子树在折叠时用零 paint/cache 范围完成必要布局，避免在内容
更新后再展开触发脏布局边界断言。折叠后内部 ticker 暂停。

`LuminaLongPressOrderable` 在实际拖动期间保活拖动源，防止源滚出懒列表缓存后
停止收到边缘自动滚动更新。接收规则、反馈、56px 边缘范围和 16px 滚动步长
保持一致，放下后释放保活。排序、跨象限移动及撤销继续使用原仓库操作。

## 验证

最终执行的测试共 248 项通过：

- 手机端 91 项：`events_list_performance_test.dart`、`news_sliver_reveal_test.dart`、
  `intelligence_markdown_test.dart`、`response_ui_test.dart`、`lumina_chat_flow_test.dart`、
  `agent_chat_ui_test.dart`、`order_gesture_test.dart`、`lumina_page_edges_test.dart`、
  `lumina_app_flow_test.dart`、`desktop_app_flow_test.dart`、`news_app_test.dart`、
  `news_realtime_test.dart`。
- `packages/lumina_ui` 全套 157 项，包括完成列表、拖动、主题、材质、可访问性等。

性能回归直接验证：1000 条任务首屏挂载少于 40 行；记忆为折叠状态时零任务行
构建；大列表滑动、折叠期间改数据再展开正常。共享列表回归验证空→1000 项和
1000 项筛选替换首帧构建少于 50 行、最后一行退出逐帧不低于空态高度，以及
重排保态、快速筛选反向、滚出视口后的完成保存。手势回归测试验证拖动源滚出
缓存后仍能自动滚动并放置，结束释放保活。

修改源码及测试的定向静态分析通过；本任务文件的 `git diff --check` 通过。
工作树同期存在其他任务的 SVG、记忆、通知、设备选择、主题等修改，保持原样；
全工作树 diff 检查涉及其他任务锁文件的 CRLF，不将其归为本任务改动。

## 项目状态

按 `coder` 的 assigned-task-paths 范围执行；工作区角色路由预览结果为
`status=routed`、执行器 `codex`。本机仍缺少 Orialis 外层项目元数据、状态、
路线图、任务目录和本地记忆数据库，未重建或推断旧任务状态。本记录承载本次
实现与自动验收状态；真机流畅度的改善幅度仍待实测。
