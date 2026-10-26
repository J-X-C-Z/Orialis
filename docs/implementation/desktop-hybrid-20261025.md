# Mac / Windows 桌面混合布局

用户明确要求 Mac 与 Windows 同步获得轻拟态玻璃、新 Chat 入口和摘要/智能 UI 能力；本次实现桌面导航与布局接入。Chat 继续复用已有 `ChatPage`、`chatRepositoryProvider` 和 `conversationId`、`messageId`、`shareId` 参数。按数据库账户名和会话 ID 保留页面身份键，不改变本地数据库与账号隔离路径。

## 布局与入口

- 900px 起保留 224px 左导航和中心页面；1440px 起在右侧增加 280px `DesktopInsightsPanel`，由独立组件读取当前账户的任务完成比例、未完成任务象限分布与最近日程。洞察栏只在非 Chat 分支显示，为聊天负责人实现的桌面三栏布局留出空间。
- 900px 以下使用可横向滚动的紧凑导航，每项固定可操作宽度，不把十个目的地压成等宽窄按钮。
- 左侧导航目的地列表可纵向滚动，个人页继续位于导航列表下方。Chat 追加为第十个分支，旧九个分支顺序保持不变。
- macOS 使用 Command+1…9、Command+0；Windows 使用 Control+1…9、Control+0。文本编辑控件获得焦点时快捷键不切页。Windows 控制键组合不会被 Mac Command 条件误判。
- 选中导航项使用 Lumina 现有语义色族和玻璃表面；桌面品牌位加载主 agent 新增并登记的 `assets/branding/orialis-neumorphic.png`。玻璃三层由 `LuminaSurface(glass: true)` 与共享主题处理。

## 同步与验证

桌面主入口由主 agent 开启轻拟态玻璃主题及 Chat 同步。本工作区测试覆盖桌面主入口主题、宽屏洞察栏、Chat 参数与仓库复用、Windows 同步开关和能力声明，以及两种平台的 0–9 导航快捷键和文本编辑焦点保护。`desktop_app_flow_test.dart` 移除了桌面禁止创建 Chat 仓库的旧测试替身。

本次按父任务约定未运行 Flutter 测试、分析或构建。交付后由主 agent 统一运行：

```sh
cd mobile
flutter test test/desktop_shell_keyboard_test.dart test/desktop_hybrid_test.dart test/desktop_app_flow_test.dart
```

测试运行前需合入主 agent 的桌面主题/同步改动、新品牌 PNG 与 pubspec 登记，以及独立的 `desktop_insights.dart` 组件。Mac/Windows 原生窗口、键盘和安装包验收仍由统一构建流程完成。
