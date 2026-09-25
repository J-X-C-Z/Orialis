# Lumina UI · Flutter

磨砂卡片、凹陷内容、液态玻璃控件与连续动效组成的 Flutter UI 库。
当前版本 **0.1.0**，仓库内使用，尚未发布到 pub.dev。

## 接入

验证环境：Flutter 3.47.4 / Dart 3.13.3。最低版本暂按已使用的新 API
保守设为 Flutter 3.47 / Dart 3.13；不宣称兼容未经测试的旧 SDK。

```yaml
dependencies:
  lumina_ui:
    path: ../packages/lumina_ui # 按项目位置调整
```

```dart
import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() => runApp(MaterialApp(
  localizationsDelegates: const [LuminaLocalizations.delegate],
  supportedLocales: LuminaLocalizations.supportedLocales,
  home: LuminaTheme(
    child: LuminaPageScaffold(
      title: '示例',
      body: LuminaPalette(
        palette: LuminaCardPalette.ocean,
        child: LuminaCollapsibleCard(
          storageId: 'example.focus',
          title: '现在关注',
          child: LuminaListRow(
            depth: LuminaSurfaceDepth.recessed,
            title: '准备明天的课程',
            onTap: () {},
          ),
        ),
      ),
    ),
  ),
));
```

应用如需完整 Material/Cupertino 日期与文本本地化，可另外接入 Flutter SDK 的
`flutter_localizations`。Lumina 内置文案支持中文、英文；未注册其 delegate 时
默认中文。业务内容由调用方翻译。

## 组件分层

| 层 | 主要 API |
| --- | --- |
| 基础 | `LuminaTheme`、`LuminaThemeData`、`LuminaColors`、`LuminaCardPalette`、`LuminaIcon`、`LuminaMotion` |
| 控件 | `LuminaButton`、`LuminaIconButton`、`LuminaTextField`、`LuminaCheck`、`LuminaSwitch`、`LuminaSegmented`、`LuminaSlidingSelection`、`LuminaValueSlider` |
| 布局 | `LuminaPageScaffold`、`LuminaTopBar`、`LuminaSection`、`LuminaListRow`、`LuminaChatBubble` |
| 卡片与动效 | `LuminaSurface`、`LuminaCollapsibleCard`、`LuminaExpandableCard`、`LuminaCompletionList`、`LuminaReveal` |
| 弹层 | `showLuminaSheet`、`showLuminaDialog`、`showLuminaMessage`、`showLuminaDatePicker`、`showLuminaTimePicker` |

只从 `package:lumina_ui/lumina_ui.dart` 导入；`lib/src/` 不作为稳定导入路径。
公共入口同时导出 Flutter widgets 类型，方便不依赖 Material 的宿主使用。

## 主题与六套配色

```dart
LuminaTheme(
  brightness: Brightness.dark,
  highPerformanceMode: true,
  data: const LuminaThemeData(
    fontFamily: 'sans-serif',
    fontScale: 1.0,
    spacingScale: 1.0,
    radiusScale: 1.0,
    motionScale: 1.0,
  ),
  child: content,
)
```

`fontScale` 调整库内字体，不替代系统文字缩放；`spacingScale` 调整材质内边距；
`radiusScale` 调整材质圆角，完整胶囊保持胶囊形状；`motionScale` 的 0–1 值
控制装饰性按压/位移强度，0 使用减少动态效果路径，不破坏布局收合的终点。
系统减少动态效果优先。尺寸 token 保留稳定默认值，业务布局由宿主控制。

配色 `mist / ocean / sage / amber / rose / lavender` 各自统一生成凸起、凹陷、
强调色及深浅模式，不在页面内单独拼颜色。`LuminaPalette` 会保留父主题其他配置。

## 可替换的宿主能力

- 折叠状态默认仅保存在内存，不访问磁盘。通过 `LuminaCardMemory.store` 注入
  `LuminaCardStore`；宿主先准备好同步读取缓存，再启动界面。存储键由宿主命名，
  多账户应用切换账户时应更换 store，避免跨账户共享折叠状态。
- 震动默认使用 Flutter `HapticFeedback.lightImpact()`。可设置
  `LuminaHaptics.confirmHandler` 接入平台专用效果；设回 null 恢复默认。
- 库不含数据库、网络、业务事件、路由框架或状态管理依赖。
- 新建的 `LuminaCompletionList` 条目需要稳定且唯一的 key；先执行业务回调，
  再播放完成动画。失败保留条目，减少动态效果仍能操作。

## 独立展示应用

```sh
cd packages/lumina_ui/example
flutter pub get
flutter run -d chrome
```

展示六套配色、深浅主题、文字缩放、性能模式、减少动效、按钮/输入/卡片/弹层。
可用 `flutter run` 选择 Android 或 iOS 设备。平台验证结果见
[验证记录](docs/verification.md)，未测试的平台不视为已验收。

## 测试与迁移

```sh
cd packages/lumina_ui
flutter test
flutter analyze lib test
cd example
flutter test
```

Orialis 用 path dependency 接入；旧 `mobile/lib/app/design/` 文件仅导出兼容层。
`Orialis*` / `App*` 类型由 typedef 指向对应 `Lumina*` 类型，没有第二份 UI 实现。
宿主的 SharedPreferences 和原生震动通道保留在移动端适配层。

[设计规范](docs/design-system.md) · [版本记录](CHANGELOG.md)

目录与导出方式参考 [Flutter 包开发文档](https://docs.flutter.dev/packages-and-plugins/developing-packages)
及 [Dart 库包结构](https://dart.dev/tools/pub/create-packages)。许可证尚未选定，
保留 `publish_to: none`；发布前需确认授权、发布者信息与平台验收范围。
