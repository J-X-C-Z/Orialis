# Changelog

## 0.1.0 — unreleased

### Flutter catalog completion — 2026-10-02

- Complete Lumina-rendered surfaces for the fixed 28-entry catalog. Navigation, tabs, floating actions, button emphasis, badges, linear progress and list tiles no longer show default SDK geometry.
- Glass radio, chip, multi-select, custom slider tracks/lenses, menus and tooltips retain Flutter's underlying focus/gesture/overlay behavior. Add `LuminaRadioGroup` for sibling arrow navigation and `LuminaMenuItem` for themed menu rows.
- Disabled/selected semantics, RTL keyboard navigation, TabController synchronization and high-text-scale scrolling are covered by focused regression tests.
- Date bounds are normalized to days; month arrows respect the range and arrow/Page keys select dates. Time operations carry unit labels. Feedback overlays inherit the active theme.
- Independent showcase covers all 28 categories with working state and optional `?catalog=1&dark=1&liquid=1&locale=zh` review links.
- Manual device screen-reader, per-platform performance and public release acceptance remain pending.


- 对照 Flutter 3.47.4 官方 Material 3 目录建立 28 项覆盖矩阵；新增主题桥接控件，保留 Flutter 的焦点、键盘与语义行为，并明确尚存的视觉差异。
- 深色基础色对齐共享设计变量；文字加入低对比刻印高光，新增系统／浅色／深色三态外观选择控件。

- 新增长按排序 LuminaLongPressOrderable 与分组拖放数据 LuminaOrderDrag，供任务、项目共用。
- 新增引用预览 LuminaQuotePreview，支持来源定位、取消引用与中英文辅助提示。
- 紧凑玻璃顶栏保留 48 点触摸区；导航底座共享滤镜，滑块碰边压缩并回弹。
- 高性能模式降低 Gaussian sigma 并移除动态放大层；普通模式保留材质与自动降级。
- 修正未经实现的 downsample / Dual Kawase 性能描述，滤镜按配置真正复用。

- 从 Orialis 提取独立 Flutter UI 库，统一 Lumina 公共命名。
- 保留磨砂纹理、液态玻璃、标题自适应肩部、凹陷外框和连续收合动效。
- 六套配色、主题覆盖、中英文提示、无插件默认状态与可注入震动。
- 独立组件展示应用、公共接口测试、原应用兼容入口。
- 尚未公开发布；非已验证平台仅提供兼容结构。
- 滑动选择器统一为凹陷轨道和独立透明玻璃滑块，导航栏与分段切换共享材质和连续弹簧动效。
- 开关移除额外卡片，开启时显示强调色与对勾；凹槽补齐柔和内阴影和轻量实时磨砂。
- 分段控件、开关与数值滑块支持长按拖动，松手吸附并确认选项。

- Added floating header, date navigator, titled content card, and lightweight calendar summary components.
- Normal-mode chrome now recovers blur quality after sustained rendering headroom; bounded material caches reduce repeated paint work.
