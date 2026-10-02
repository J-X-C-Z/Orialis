# Flutter Material 3 component coverage

Baseline: Flutter **3.47.4** (framework `9584c6713b`, 2026-09-10), Dart
**3.13.3**. Inventory: [Flutter Material 3 component catalog](https://docs.flutter.dev/ui/widgets/material),
consulted 2026-09-28. This is a fixed 28-entry component inventory; it excludes
Material 2 legacy widgets and Flutter layout primitives.

All entries now render Lumina material rather than the SDK's default Material
geometry. `Lumina` means the package owns the control's rendering and interaction;
`Lumina + SDK behavior` means the material is authored here while Flutter retains
its tested gesture, focus, semantics or overlay mechanics. The public constructors
remain compatible with the initial catalog. No per-item live backdrop filter is
added to repeated rows, chips or menu items; their glass is painted, while the
navigation chrome can opt into shared backdrop blur.

| Catalog group | Component | Lumina API | Coverage |
| --- | --- | --- | --- |
| Actions | Common buttons | `LuminaButton`, `LuminaMaterialButton` (filled, tonal, elevated, outlined, text) | Lumina |
| Actions | FloatingActionButton | `LuminaFloatingActionButton` | Lumina |
| Actions | Extended FloatingActionButton | `LuminaFloatingActionButton(label: …)` | Lumina |
| Actions | IconButton | `LuminaIconButton` | Lumina |
| Actions | SegmentedButton | `LuminaSegmented<T>`, `LuminaMultiSegmented<T>` | Lumina single selection / Lumina multi-selection with SDK focus |
| Communication | Badge | `LuminaBadge` | Lumina |
| Communication | LinearProgressIndicator | `LuminaLinearProgress` | Lumina |
| Communication | SnackBar | `showLuminaMessage` | Lumina overlay; host ScaffoldMessenger not required |
| Containment | AlertDialog | `showLuminaDialog`, `LuminaDialog` | Lumina |
| Containment | Bottom sheet | `showLuminaSheet` | Lumina |
| Containment | Card | `LuminaSurface` | Lumina |
| Containment | Divider | `LuminaDivider`, `LuminaEngravedDivider` | Lumina |
| Containment | ListTile | `LuminaListRow`, `LuminaListTile` | Lumina |
| Navigation | AppBar | `LuminaTopBar`, `LuminaPageScaffold` | Lumina |
| Navigation | Bottom app bar | `LuminaBottomAppBar`, `LuminaBottomActionBar` | Lumina |
| Navigation | NavigationBar | `LuminaNavigationBar` | Lumina |
| Navigation | NavigationDrawer | `LuminaNavigationDrawer` | Lumina |
| Navigation | NavigationRail | `LuminaNavigationRail` | Lumina |
| Navigation | TabBar | `LuminaTabs` | Lumina |
| Selection | Checkbox | `LuminaCheck` | Lumina |
| Selection | Chip | `LuminaChip` | Lumina + SDK behavior |
| Selection | DatePicker | `showLuminaDatePicker` | Lumina |
| Selection | Menu | `LuminaMenuAnchor`, `LuminaMenuItem` | Lumina + SDK behavior |
| Selection | Radio | `LuminaRadio<T>`, `LuminaRadioGroup<T>` | Lumina lens + SDK `RadioGroup`; `LuminaRadioGroup` enables sibling traversal |
| Selection | Slider | `LuminaValueSlider`, `LuminaContinuousSlider`, `LuminaRangeSlider` | Lumina discrete values / custom Lumina tracks and lenses with SDK slider behavior |
| Selection | Switch | `LuminaSwitch` | Lumina |
| Selection | TimePicker | `showLuminaTimePicker` | Lumina |
| Text input | TextField | `LuminaTextField` | Lumina |

## State coverage and verification (2026-10-02)

The standalone `example/` provides all 28 categories with live actions and state,
including disabled controls, multiple selection, shared bar/rail/drawer selection,
tabs, editable input, continuous/discrete/range sliders, menu dismissal, dialogs,
sheets, date and time results. Open `?catalog=1` to review the catalog directly;
`?dark=1&liquid=1&locale=zh` initializes dark clear-glass Chinese presentation.
The same controls support the original sculpted theme and opt-in clear liquid
glass. High contrast/reduced transparency retain solid fills and focus cues.

Automated regressions exercise keyboard activation, directional navigation,
disabled destinations, selected semantics, tab-controller synchronization,
arrow-key radio groups, chips/deletion, sliders, menus, date bounds and adaptive
text layout. The date picker normalizes all limits to calendar days; its keyboard
supports arrows and Page Up/Page Down, and its month buttons stop at range limits.
Time stepper buttons announce both operation and units. Transient messages inherit
the active Lumina palette/material and expose a live-region announcement.

Visual renderer coverage is complete for the **fixed 28-entry inventory**.
This does not establish every Material behavioral edge case, manual screen-reader
quality or platform-specific performance. Android/iOS/macOS/Windows/Linux manual
screen-reader and device visual acceptance remain open. SDK upgrades and newly
added upstream controls require a separate inventory update.

The shared source of truth for baseline colors, spacing, radii and motion is
`../../lumina_tokens/lumina.v1.json`. `python3 ../lumina_tokens/generate_flutter.py` generates Flutter const values from that JSON; run it after token edits and use `--check` in validation. Flutter maps its light values through
`LuminaBaseColors` and its dark values through `LuminaColors`; the six optional
palette tints are Flutter-specific derived tonal families. The text engraving
uses a very low contrast one-pixel shadow while preserving opaque main glyphs.
