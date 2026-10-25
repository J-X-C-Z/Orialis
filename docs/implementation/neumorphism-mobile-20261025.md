# Orialis 手机端 · Neumorphism UI 第一轮重绘（2026-10-25）

## 依据与范围

- 源代码：`mobile/` Flutter 主应用；现有设计层：`packages/lumina_ui/`。
- 视觉参考：[Neumorphism UI](https://neumorphism-ui.andongmin.com/zh/components/breadcrumb) 及其 Card、Button、Input、Tabs、Calendar、Switch、Progress 等组件。参考库是 React / Tailwind，不能直接作为 Flutter 运行时依赖，因此本次在 Lumina 的原生组件上复现材料风格。
- 五个底部路由保持不变：今日、事件（四象限/项目）、聊天、日历、我的。次级路由包括记忆、系统提醒、设备中心、手环和项目。
- 不动 Rust 服务端、同步、任务/日程仓储、Agent 对话存储及系统权限。

## 样式映射

| 参考组件 | Flutter 落地 | 风格变化 |
| --- | --- | --- |
| Card / Image Card | `LuminaSurface`、`LuminaSection` | 柔和双向环境阴影、冷白表面、取消浮雕式厚底边 |
| Input / Field | `LuminaTextField` | 内凹渐变字段、低反差轮廓、原有焦点态 |
| Tabs / Navigation | `OrialisMobileNavigationOverlay` + `LuminaSegmented` | 实色轻拟态悬浮导航、淡蓝选中表面 |
| Badge / Progress / Slider | 原 Lumina 对应组件 | 继承蓝灰配色和背景材质 |
| Switch | `LuminaSwitch` | 延续原有语义及触控尺寸，使用主题色 |
| Dashboard card | `TodayPage._softStat` | 依据现有任务与日程 stream 呈现三张可点击数据卡 |

### Color tokens（浅色 / 深色）

- Canvas: `#EAF0F8` / `#161E2B`
- Surface: `#F0F4FA` / `#202B3A`
- Raised: `#F2F6FC` / `#293447`
- Inset: `#DFE7F3` / `#172131`
- Accent: `#477BE0` / `#9CC2FF`
- Ink: `#243046` / `#F1F5FC`

## 开启、回退与隔离

手机 Flutter 主入口默认启用新样式；点击 **我的 → 外观与体验 → 轻拟态界面** 可即时切回原 Lumina 样式，并以 SharedPreferences 存储，重启后生效。当前独立开发分支是 `ui/neumorphism-mobile-20261025`，未修改 main。

`LuminaThemeData.visualStyle` 的默认值是 `LuminaVisualStyle.original`，因此桌面、独立 News App、组件库示例以及其他未 opt-in 的调用方继续沿用原外观。原有明暗色进度过渡、业务状态、键盘与屏幕阅读能力不变。

## 验证状态

本提交附带 `packages/lumina_ui/test/neumorphism_palette_test.dart`，覆盖样式隔离、继承和浅深色结构。当前对话执行环境未安装 Flutter / Dart SDK，所以 **未执行编译、静态分析、Widget tests、Android 真机及像素视觉验收**。这是功能结构保留的第一轮 UI skin，不应标记为全面验收或直接发布。

建议后续验证命令：

```sh
cd packages/lumina_ui
flutter test test/neumorphism_palette_test.dart
flutter analyze lib test
cd ../../mobile
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter run
```

还需用低端 Android 机型检查长列表滚动、连续阴影绘制、深色模式、键盘弹出时底栏显隐、无障碍文本放大及屏幕阅读。
