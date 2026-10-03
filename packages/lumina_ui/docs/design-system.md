# Lumina Flutter design and interaction controls

通用设计规范： [Lumina Design System](https://github.com/J-X-C-Z/Lumina)。本页负责Flutter实现细节；日历、子任务和项目摘要段属于Orialis宿主模式，不构成Core领域规则。共享数值来源为 [`lumina.v1.json`](../../lumina_tokens/lumina.v1.json)，Web使用CSS近似映射。

## Two material modes

默认 `LuminaThemeData.liquidGlass=false` 保留雕刻材质、微纹理与低对比文字高光；true选择无颗粒清透表面、薄边缘与漫射阴影。内容仍保持稳定层级。材质与性能独立：`LuminaTheme.highPerformanceMode`默认true；正常模式由宿主显式选择。

## Sliding selection material

`LuminaSlidingSelection` paints one stationary glass recess below the labels
and one raised transparent lens above them. The recess can opt into a clipped backdrop blur, with a stable inner boundary
and muted tint. The active lens can magnify labels in normal mode; high-performance
and reduced-motion branches remove the moving magnifier. BlurS/BlurM describe
actual Flutter Gaussian sigma 3.5/5.5, not the shared JSON glass values12/6.
Reduced transparency and high contrast use opaque material without backdrop blur. The recess does not travel or animate.
Navigation, segmented selection, switches and discrete value sliders share
this implementation, the spring and capsule radius. Each accepts a long press
on the lens, drags continuously and commits the nearest stop on release.
`LuminaSwitch` paints only the recess and lens into its parent card, with no
extra outer card. On adds accent tint and a check mark; off remains quiet.

## Ownership and shared controls

Page code supplies content and actions. Material, heading metrics, disclosure,
selection lenses and transition timing belong in `packages/lumina_ui/lib/src/`.

- `LuminaCardHeader`: 18sp semibold, top-left origin at the card's 16dp inset.
  A trailing action never changes the heading origin. A disclosure title owns
  its tap target; trailing buttons retain their own actions.
  The top-left shoulder follows the measured first text line (system font and
  text scaling included), plus the disclosure clearance. It is bounded by the
  available card width and transitions down with tangent-continuous curves;
  never use a percentage of card width for the title shelf.
- Recessed task/schedule titles: 16sp, medium weight, 1.35 line height, system
  font. Card heading-to-body spacing is 12dp.
- `LuminaCollapsibleCard`: default expanded, supports host-injected folding storage (memory-only by default),
  preserves mounted content, and clips/reveals from the top using the shared
  220ms ease-out. A collapsed card retains its heading and a short status.
- `LuminaExpandableCard`: projects expand at their list position. Only one
  project is expanded; other projects remain visible and move with layout.
  Milestone creation lives beside the milestone section, not in the main title.
  The summary shows the goal, stored project status (active/completed/archived),
  milestone progress and the next step.
- `LuminaSlidingSelection`: paints above labels, ignores hit testing and uses
  a clipped 1.08x lens. Spring retargeting retains position and velocity.
  All controls commit a long-press drag only on release. The outer frame and
  lens both use the capsule radius. High contrast/reduced transparency uses 1x.

## Material cost

Every recessed `LuminaSurface` must have a material card ancestor. The shared
surface automatically supplies a raised host if missing, and does not add a
second frame when one exists. Month agendas group time columns and recessed
events inside one raised host; expanded month summaries have small card shells.

Use `LuminaPalette(palette: LuminaCardPalette.ocean, child: ...)` to select a
complete family. Available families: mist, ocean, sage, amber, rose, lavender.
Each derives raised body, recessed body, glass accent and readable text together
in light/dark mode. Priority mapping: rose important+urgent, amber urgent,
ocean important, sage ordinary, mist unclassified. Do not add page-local hex
colors for these roles; `LuminaTint` remains a low-level extension point.

Completion closure uses a top-anchored anti-aliased opening, matching layout
collapse, with a rim that follows the opening. Never combine a moving recess
with a second hard rectangular crop or a painted horizontal cover strip.
Keep existing reversible timing, reduced-motion behavior and immediate saves.

Content cards use a cached 64x64 grain tile, a narrow bottom edge and a soft
top bevel. The texture is static and shared: folding must not regenerate
thousands of grain points at every intermediate height. Glass controls remain
translucent and use the same light direction. Do not add permanent animation
tickers or per-row live backdrop blur for material decoration.

## Calendar

Month view has exactly two stops: compact month plus selected day's agenda,
and expanded month showing event summaries. Its handle supports direct drag,
velocity-based settling and reversal from the current displayed height.
It never folds into week view. Week is a separate seven-day selector and seven
daily cards, containing schedules only; tapping a date scrolls to its daily card.
Day gives each schedule its own raised card with its attached tasks inside.
Day and week share recessed schedule rows, a fixed leading start/end time
column, all-day items first and a quiet ongoing marker. Date controls use equal
cell dimensions and the shared soft-glass press response. Selection survives
view changes.

Calendar density includes scheduled items and incomplete tasks due that day.
The neutral blue fill grows with item count; the small status mark distinguishes
ordinary, important, urgent, and important-plus-urgent. Explicit schedule
importance defaults to false. Color is supplemented by accessible item-count
labels and textual importance in details.

## Child tasks

Task editors expose a child section for root tasks. Schedule details expose
attached tasks for that specific schedule. Both use `TaskChildrenPanel` and the
same editor, recessed rows, completion feedback and source labels. A new parent
must be saved before it can receive children. Today/Events continue displaying
eligible child tasks with their source.

Completing a parent completes its children; completing all children completes
the parent. Reopening a child reopens the parent. Deleting a parent or schedule
also deletes its children; the confirmation must state this scope. The data
and sync contract is documented in `subevents-contract.md`.

## Accessibility and verification

System font scaling is retained. Check 320dp at 2x text, independent trailing
actions, interrupted folds, cross-filter endpoint-only content, long navigation
drags, and child creation from both task and schedule context. Reduced motion
removes positional travel; folding and selection remain operable.

## Package ownership

Business data, child-task propagation, calendar calculations and navigation routes remain in the host application. The library owns only the generic UI and callback contracts above. Do not move server or synchronization implementations into the UI package.

## Android compact glass and reply controls

Persistent navigation and top bars use a clipped Gaussian backdrop with a
translucent tint and rim. Normal mode uses sigma 5.5; high-performance mode uses
sigma 3.5, flat shadows, and no moving magnification layer. These are Flutter
ImageFilter values: there is no custom downsample or Dual Kawase implementation.
The frame watcher lowers normal-mode sigma after sustained slow frames. List
rows never opt into backdrop filtering. High contrast/reduced transparency use
opaque chrome; reduced motion removes lens distortion.

Compact top bars use 4-point vertical padding with a 48-point minimum content area;
the full top-bar content height token is 56. Interactive targets remain at least48.
Long-press scrubbing compresses the navigation lens against the well edge;
the lens remains inside its bounds and native haptics fire once per contact.
Hosts with an already blurred base set `LuminaSlidingSelection.backdrop: false`
to avoid two filters over the same pixels.

`LuminaQuotePreview(title:, text:, onTap:, onDismiss:)` is the shared reply
preview. It keeps a 48-point action target, truncates long previews, and adapts
to the current palette. Reply identities and text snapshots remain host data.

### 长按排序

`LuminaLongPressOrderable<T>` 提供同组长按排序、跨组接收、拖动反馈与滚动边缘自动滚动。
领域层负责保存排序与撤销属性变化；控件不持有任务或项目数据。
`LuminaOrderDrag<T>` 可用于整个空分组的 DragTarget，确保没有条目时仍能接收。
减少动态效果开启时不播放目标缩放过渡。

### Floating calendar and event content

`LuminaFloatingHeader` keeps only its capsule fixed. Apply the builder's inset to scroll padding, so rows can travel behind the glass. Date navigation belongs inside the scroll body. `LuminaDateNavigator` reserves 12px between date and arrows and permits scaled text wrapping.

`LuminaTitledContentCard` keeps its semantic heading in populated and empty states. Use separate schedule and deadline cards. `LuminaCalendarSummary` is a lightweight one-line label with a distinct schedule/deadline marker; limit month cells to two entries, one per category when both exist, and add an overflow count. Full information belongs below the grid.

Normal-mode glass uses bounded shape/gradient caches and batched grain drawing. Blur adapts to the display refresh budget, lowers after 12 consecutive slow frames, and recovers after 120 frames with headroom. A two-second cooldown prevents oscillation; automatic reduction retains at least BlurS. High-performance and reduced-transparency settings remain authoritative.

## Complete Flutter catalog material (2026-10-02)

The fixed 28-entry catalog now renders Lumina surfaces, lenses and tracks across
all component categories. Slider/radio/chip/menu mechanics continue to use SDK
input and focus infrastructure; their default Material geometry is replaced.
The catalog wrappers retain public constructors and use the active light/dark
palette, sculpted/clear-glass setting and accessibility substitutions.

Popup menus, tooltips, dialogs, sheets and messages capture Lumina theme and
MediaQuery preferences from their triggering context. Dialogs (including date and
time pickers), bottom sheets and popup menu containers use an opaque raised
card even when clear glass is enabled globally. Only their container opts out via
`LuminaSurface(liquidGlass: false)`; child controls keep the triggering theme.
Interactive list rows inside sheets also use opaque card surfaces; attachment
pickers and action menus never turn those rows into glass merely because they
have a tap callback. Rows outside a sheet continue to follow the page theme.
Navigation visibility scrolls the component's own viewport without changing the containing page.
State examples and verification boundaries live in material3-coverage.md.

### Card overlay controls and top tabs

Bottom sheet contents enter `LuminaCardScope`, which gives all descendant
button and icon surfaces opaque card paint without changing the page theme.
The scope also disables the selection well/lens glass painters and refraction.
`LuminaTabs` and `LuminaSegmented` use this material for their shell and selected
state. Calendar view selection opts into its translucent well and lens with
`LuminaSegmented(transparent: true)`. Ordinary page buttons keep their configured
material.
