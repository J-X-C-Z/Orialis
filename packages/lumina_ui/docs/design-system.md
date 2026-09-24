# Lumina content and interaction controls

## Sliding selection material

`LuminaSlidingSelection` paints one stationary glass recess below the labels
and one raised transparent lens above them. The recess has a clipped, small
backdrop blur, soft inner shadow and muted frost; the lens magnifies labels.
High-performance mode uses BlurS, regular mode BlurM. Reduced transparency and
high contrast use opaque material. The recess does not travel or animate.
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
- `LuminaCollapsibleCard`: default expanded, saves folding preference locally,
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
