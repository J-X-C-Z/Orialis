part of 'lumina_catalog.dart';

/// Shares one keyboard traversal and selection registry among sibling radios.
class LuminaRadioGroup<T> extends StatelessWidget {
  const LuminaRadioGroup({
    required this.groupValue,
    required this.onChanged,
    required this.child,
    super.key,
  });
  final T? groupValue;
  final ValueChanged<T?> onChanged;
  final Widget child;
  @override
  Widget build(BuildContext context) => m.RadioGroup<T>(
    groupValue: groupValue,
    onChanged: onChanged,
    child: child,
  );
}

Widget _luminaRadioHost<T>(
  BuildContext context,
  T? groupValue,
  ValueChanged<T?>? onChanged,
  Widget child,
) => m.RadioGroup.maybeOf<T>(context) != null
    ? child
    : m.RadioGroup<T>(
        groupValue: groupValue,
        onChanged: onChanged ?? (_) {},
        child: child,
      );

/// A glass selection lens with Flutter's radio focus and semantics behavior.
class LuminaRadio<T> extends StatelessWidget {
  const LuminaRadio({
    required this.value,
    required this.groupValue,
    required this.onChanged,
    super.key,
  });
  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final registry = m.RadioGroup.maybeOf<T>(context);
    final selected =
        value == (registry != null ? registry.groupValue : groupValue);
    final enabled = onChanged != null;
    return LuminaMaterialBridge(
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: ExcludeSemantics(
              child: SizedBox.square(
                dimension: 26,
                child: LuminaSurface(
                  padding: const EdgeInsets.all(6),
                  radius: 13,
                  glass: selected && enabled,
                  depth: LuminaSurfaceDepth.raised,
                  color: selected && enabled
                      ? theme.colors.accentSoft
                      : theme.colors.recessedSurface,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? enabled
                                ? theme.colors.accent
                                : theme.colors.muted
                          : m.Colors.transparent,
                    ),
                  ),
                ),
              ),
            ),
          ),
          _luminaRadioHost<T>(
            context,
            groupValue,
            onChanged,
            m.Radio<T>(
              value: value,
              enabled: enabled,
              fillColor: const m.WidgetStatePropertyAll(m.Colors.transparent),
              backgroundColor: const m.WidgetStatePropertyAll(
                m.Colors.transparent,
              ),
              side: m.BorderSide.none,
              innerRadius: const m.WidgetStatePropertyAll(0),
              overlayColor: m.WidgetStateProperty.resolveWith((states) {
                if (states.contains(m.WidgetState.focused) ||
                    states.contains(m.WidgetState.hovered) ||
                    states.contains(m.WidgetState.pressed)) {
                  return theme.colors.accent.withValues(alpha: .18);
                }
                return m.Colors.transparent;
              }),
              materialTapTargetSize: m.MaterialTapTargetSize.padded,
            ),
          ),
        ],
      ),
    );
  }
}

/// Multiple glass lenses with native button focus and explicit selection state.
class LuminaMultiSegmented<T> extends StatelessWidget {
  const LuminaMultiSegmented({
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.multiSelectionEnabled = true,
    super.key,
  }) : assert(segments.length > 0);
  final List<m.ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool multiSelectionEnabled;

  void _choose(T value) {
    if (onSelectionChanged == null) return;
    final next = multiSelectionEnabled ? Set<T>.of(selected) : <T>{};
    if (multiSelectionEnabled && next.contains(value)) {
      next.remove(value);
    } else {
      next.add(value);
    }
    onSelectionChanged!(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaMaterialBridge(
      child: LuminaSurface(
        depth: LuminaSurfaceDepth.raised,
        radius: LuminaControlSize.capsuleRadius,
        padding: const EdgeInsets.all(4),
        child: FocusTraversalGroup(
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowLeft):
                  DirectionalFocusIntent(TraversalDirection.left),
              SingleActivator(LogicalKeyboardKey.arrowRight):
                  DirectionalFocusIntent(TraversalDirection.right),
            },
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: segments.map((segment) {
                final active = selected.contains(segment.value);
                return MergeSemantics(
                  child: Semantics(
                    selected: active,
                    inMutuallyExclusiveGroup: !multiSelectionEnabled,
                    child: m.TextButton(
                      onPressed: onSelectionChanged != null && segment.enabled
                          ? () => _choose(segment.value)
                          : null,
                      style: m.ButtonStyle(
                        minimumSize: const m.WidgetStatePropertyAll(
                          Size(48, 48),
                        ),
                        padding: const m.WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                        shape: const m.WidgetStatePropertyAll(
                          m.StadiumBorder(),
                        ),
                        backgroundColor: const m.WidgetStatePropertyAll(
                          m.Colors.transparent,
                        ),
                        overlayColor: const m.WidgetStatePropertyAll(
                          m.Colors.transparent,
                        ),
                        textStyle: m.WidgetStatePropertyAll(
                          theme.textTheme.labelMedium,
                        ),
                        foregroundColor: m.WidgetStateProperty.resolveWith(
                          (states) => states.contains(m.WidgetState.disabled)
                              ? theme.colors.muted
                              : theme.colors.ink,
                        ),
                        animationDuration: LuminaTheme.motionReducedOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 140),
                        backgroundBuilder: (context, states, child) {
                          final focused = states.contains(
                            m.WidgetState.focused,
                          );
                          final highlighted =
                              focused ||
                              states.contains(m.WidgetState.hovered) ||
                              states.contains(m.WidgetState.pressed);
                          return LuminaSurface(
                            padding: EdgeInsets.zero,
                            glass: active,
                            diffuseGlass: active,
                            radius: LuminaControlSize.capsuleRadius,
                            color: active
                                ? theme.colors.accentSoft
                                : highlighted
                                ? theme.colors.surface
                                : m.Colors.transparent,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  LuminaControlSize.capsuleRadius,
                                ),
                                border: focused
                                    ? Border.all(
                                        color: theme.colors.accent,
                                        width: 2,
                                      )
                                    : null,
                              ),
                              child: child,
                            ),
                          );
                        },
                      ),
                      child: segment.tooltip == null
                          ? _segmentContent(segment)
                          : LuminaTooltip(
                              message: segment.tooltip!,
                              child: _segmentContent(segment),
                            ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _segmentContent(m.ButtonSegment<T> segment) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (segment.icon != null) segment.icon!,
      if (segment.icon != null && segment.label != null)
        const SizedBox(width: 6),
      if (segment.label != null) Flexible(child: segment.label!),
    ],
  );
}

m.SliderThemeData _luminaSliderTheme(BuildContext context) {
  final theme = LuminaTheme.of(context);
  final opaque =
      theme.reduceTransparency ||
      (MediaQuery.maybeOf(context)?.highContrast ?? false);
  final reduced = LuminaTheme.motionReducedOf(context);
  final scale = theme.data.radiusScale;
  return m.SliderThemeData(
    trackHeight: 10 * scale,
    activeTrackColor: theme.colors.accent,
    inactiveTrackColor: theme.colors.recessedSurface,
    disabledActiveTrackColor: theme.colors.muted,
    disabledInactiveTrackColor: theme.colors.recessedSurface,
    thumbColor: theme.colors.raisedSurface,
    disabledThumbColor: theme.colors.surface,
    overlayColor: theme.colors.accent.withValues(alpha: .16),
    overlayShape: m.RoundSliderOverlayShape(overlayRadius: 23 * scale),
    thumbShape: _LuminaSliderLens(
      opaque: opaque,
      reduced: reduced,
      scale: scale,
      outline: theme.colors.outline,
    ),
    rangeThumbShape: _LuminaRangeLens(
      opaque: opaque,
      reduced: reduced,
      scale: scale,
      outline: theme.colors.outline,
    ),
    trackShape: _LuminaSliderTrack(
      opaque: opaque,
      outline: theme.colors.outline,
    ),
    rangeTrackShape: _LuminaRangeTrack(
      opaque: opaque,
      outline: theme.colors.outline,
    ),
    valueIndicatorColor: theme.colors.raisedSurface,
    valueIndicatorStrokeColor: theme.colors.outline,
    valueIndicatorTextStyle: theme.textTheme.labelSmall,
    valueIndicatorShape: _LuminaSliderValue(opaque: opaque),
    showValueIndicator: m.ShowValueIndicator.onlyForContinuous,
  );
}

class LuminaContinuousSlider extends StatelessWidget {
  const LuminaContinuousSlider({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.label,
    super.key,
  });
  final double value, min, max;
  final String? label;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) => LuminaMaterialBridge(
    child: m.SliderTheme(
      data: _luminaSliderTheme(context),
      child: m.Slider(
        value: value,
        min: min,
        max: max,
        label: label,
        onChanged: onChanged,
      ),
    ),
  );
}

class LuminaRangeSlider extends StatelessWidget {
  const LuminaRangeSlider({
    required this.values,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    super.key,
  });
  final m.RangeValues values;
  final double min, max;
  final ValueChanged<m.RangeValues>? onChanged;

  @override
  Widget build(BuildContext context) => LuminaMaterialBridge(
    child: m.SliderTheme(
      data: _luminaSliderTheme(context),
      child: m.RangeSlider(
        values: values,
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    ),
  );
}

/// The SDK owns chip actions and focus; the capsule is Lumina glass.
class LuminaChip extends StatelessWidget {
  const LuminaChip({
    required this.label,
    this.selected = false,
    this.onSelected,
    this.onDeleted,
    super.key,
  });
  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaMaterialBridge(
      child: LuminaSurface(
        padding: EdgeInsets.zero,
        glass: selected,
        diffuseGlass: selected,
        depth: LuminaSurfaceDepth.raised,
        radius: LuminaControlSize.capsuleRadius,
        color: selected ? theme.colors.accentSoft : theme.colors.surface,
        child: m.RawChip(
          label: label,
          selected: selected,
          onSelected: onSelected,
          onDeleted: onDeleted,
          tapEnabled: onSelected != null,
          isEnabled: onSelected != null || onDeleted != null,
          showCheckmark: selected,
          checkmarkColor: theme.colors.accent,
          labelStyle: theme.textTheme.labelMedium,
          deleteIcon: Semantics(
            button: true,
            enabled: onDeleted != null,
            child: Icon(
              m.Icons.close_rounded,
              size: 18,
              color: theme.colors.muted,
            ),
          ),
          backgroundColor: m.Colors.transparent,
          selectedColor: m.Colors.transparent,
          disabledColor: m.Colors.transparent,
          color: const m.WidgetStatePropertyAll(m.Colors.transparent),
          side: m.BorderSide.none,
          shape: const m.StadiumBorder(),
          elevation: 0,
          pressElevation: 0,
          surfaceTintColor: m.Colors.transparent,
          materialTapTargetSize: m.MaterialTapTargetSize.padded,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          chipAnimationStyle: m.ChipAnimationStyle(
            selectAnimation: AnimationStyle(
              duration: LuminaTheme.motionReducedOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
            ),
          ),
        ),
      ),
    );
  }
}

/// A positioned surface contributes no speculative intrinsic measurements.
/// Flutter menus measure their children before laying out the popup.
class _LuminaMenuGlass extends StatelessWidget {
  const _LuminaMenuGlass({
    required this.child,
    required this.radius,
    required this.color,
    this.glass = false,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final double radius;
  final Color color;
  final bool glass;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: LuminaSurface(
              padding: EdgeInsets.zero,
              depth: LuminaSurfaceDepth.raised,
              glass: glass,
              color: color,
              radius: radius,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
      Padding(padding: padding, child: child),
    ],
  );
}

m.ButtonStyle _luminaMenuButtonStyle(BuildContext context) {
  final theme = LuminaTheme.of(context);
  return m.ButtonStyle(
    minimumSize: const m.WidgetStatePropertyAll(Size(48, 48)),
    padding: const m.WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ),
    textStyle: m.WidgetStatePropertyAll(theme.textTheme.bodyMedium),
    foregroundColor: m.WidgetStateProperty.resolveWith(
      (states) => states.contains(m.WidgetState.disabled)
          ? theme.colors.muted
          : theme.colors.ink,
    ),
    backgroundColor: const m.WidgetStatePropertyAll(m.Colors.transparent),
    overlayColor: const m.WidgetStatePropertyAll(m.Colors.transparent),
    shape: m.WidgetStatePropertyAll(
      m.RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14 * theme.data.radiusScale),
      ),
    ),
    animationDuration: LuminaTheme.motionReducedOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 140),
    backgroundBuilder: (context, states, child) {
      final focused = states.contains(m.WidgetState.focused);
      final active =
          focused ||
          states.contains(m.WidgetState.hovered) ||
          states.contains(m.WidgetState.pressed);
      return _LuminaMenuGlass(
        padding: EdgeInsets.zero,
        radius: 14,
        glass: active,
        color: active ? theme.colors.accentSoft : m.Colors.transparent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14 * theme.data.radiusScale),
            border: focused
                ? Border.all(color: theme.colors.accent, width: 2)
                : null,
          ),
          child: child ?? const SizedBox.shrink(),
        ),
      );
    },
  );
}

/// A native glass menu item. SDK MenuItemButton children are also themed by
/// LuminaMenuAnchor; this API avoids requiring a Material import at call sites.
class LuminaMenuItem extends StatelessWidget {
  const LuminaMenuItem({
    required this.child,
    required this.onPressed,
    this.leadingIcon,
    this.trailingIcon,
    super.key,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final Widget? leadingIcon, trailingIcon;

  @override
  Widget build(BuildContext context) => m.MenuItemButton(
    onPressed: onPressed,
    leadingIcon: leadingIcon,
    trailingIcon: trailingIcon,
    style: _luminaMenuButtonStyle(context),
    child: child,
  );
}

// SDK overlays capture InheritedTheme values; LuminaTheme is an ordinary
// InheritedWidget and must be carried into the popup explicitly.
Widget _luminaSelectionPopupTheme(BuildContext context, Widget child) {
  final theme = LuminaTheme.of(context);
  return MediaQuery(
    data: MediaQuery.maybeOf(context) ?? const MediaQueryData(),
    child: Directionality(
      textDirection: Directionality.of(context),
      child: LuminaTheme(
        brightness: theme.brightness,
        tint: theme.tint,
        data: theme.data,
        reduceTransparency: theme.reduceTransparency,
        highPerformanceMode: theme.highPerformanceMode,
        child: child,
      ),
    ),
  );
}

/// Glass popup with the SDK's traversal, outside-tap dismissal and menu anchor.
class LuminaMenuAnchor extends StatelessWidget {
  const LuminaMenuAnchor({
    required this.menuChildren,
    required this.builder,
    super.key,
  });
  final List<Widget> menuChildren;
  final m.MenuAnchorChildBuilder builder;

  @override
  Widget build(BuildContext context) => LuminaMaterialBridge(
    child: m.MenuButtonTheme(
      data: m.MenuButtonThemeData(style: _luminaMenuButtonStyle(context)),
      child: m.MenuAnchor(
        style: const m.MenuStyle(
          backgroundColor: m.WidgetStatePropertyAll(m.Colors.transparent),
          surfaceTintColor: m.WidgetStatePropertyAll(m.Colors.transparent),
          shadowColor: m.WidgetStatePropertyAll(m.Colors.transparent),
          elevation: m.WidgetStatePropertyAll(0),
          padding: m.WidgetStatePropertyAll(EdgeInsets.zero),
        ),
        menuChildren: [
          _luminaSelectionPopupTheme(
            context,
            SizedBox(
              width: ((MediaQuery.maybeOf(context)?.size.width ?? 400) - 32)
                  .clamp(64.0, 280.0),
              child: _LuminaMenuGlass(
                color: LuminaTheme.of(context).colors.raisedSurface,
                glass: true,
                radius: 22,
                padding: const EdgeInsets.all(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: menuChildren,
                ),
              ),
            ),
          ),
        ],
        builder: builder,
      ),
    ),
  );
}

/// SDK hover/long-press behavior with a Lumina glass tooltip and explicit label.
class LuminaTooltip extends StatelessWidget {
  const LuminaTooltip({required this.message, required this.child, super.key});
  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final maxWidth = ((MediaQuery.maybeOf(context)?.size.width ?? 400) - 48)
        .clamp(64.0, 360.0);
    return LuminaMaterialBridge(
      child: Semantics(
        tooltip: message,
        child: m.Tooltip(
          excludeFromSemantics: true,
          padding: EdgeInsets.zero,
          decoration: const BoxDecoration(color: m.Colors.transparent),
          richMessage: WidgetSpan(
            child: _luminaSelectionPopupTheme(
              context,
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: LuminaSurface(
                  glass: true,
                  depth: LuminaSurfaceDepth.raised,
                  radius: 14,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Text(message, style: theme.textTheme.labelSmall),
                ),
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// Sliders keep their native gestures, keyboard commands, hit areas and spoken
// values. Only the painted track, thumb and value bubble are replaced.
void _paintLuminaLens(
  Canvas canvas,
  Offset center,
  m.SliderThemeData theme, {
  required double enabled,
  required double pressure,
  required bool opaque,
  required double scale,
  required Color outline,
}) {
  final rect = Rect.fromCenter(
    center: center,
    width: (30 + pressure * 2) * scale,
    height: (26 - pressure) * scale,
  );
  final body = RRect.fromRectAndRadius(rect, Radius.circular(13 * scale));
  final color = Color.lerp(
    theme.disabledThumbColor,
    theme.thumbColor,
    enabled,
  )!;
  canvas.drawRRect(
    body.shift(Offset(0, 2 * scale)),
    Paint()..color = const Color(0x1A000000),
  );
  canvas.drawRRect(
    body,
    opaque
        ? (Paint()..color = color)
        : (Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(color, m.Colors.white, .38)!,
                color,
                Color.lerp(color, theme.activeTrackColor, .18)!,
              ],
            ).createShader(rect)),
  );
  canvas.drawRRect(
    body.deflate(.5),
    Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = opaque ? 1.5 : 1,
  );
  if (!opaque) {
    canvas.drawLine(
      rect.topLeft + Offset(7 * scale, 3 * scale),
      rect.topRight + Offset(-7 * scale, 3 * scale),
      Paint()
        ..color = m.Colors.white.withValues(alpha: .65)
        ..strokeWidth = 1,
    );
  }
}

void _paintLuminaTrack(
  Canvas canvas,
  Rect rect,
  Rect active,
  m.SliderThemeData theme,
  double enabled,
  bool opaque,
  Color outline,
) {
  final radius = Radius.circular(rect.height / 2);
  final body = RRect.fromRectAndRadius(rect, radius);
  final inactiveColor = Color.lerp(
    theme.disabledInactiveTrackColor,
    theme.inactiveTrackColor,
    enabled,
  )!;
  final activeColor = Color.lerp(
    theme.disabledActiveTrackColor,
    theme.activeTrackColor,
    enabled,
  )!;
  canvas.drawRRect(body, Paint()..color = inactiveColor);
  canvas.save();
  canvas.clipRRect(body);
  if (!active.isEmpty) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(active, radius),
      opaque
          ? (Paint()..color = activeColor)
          : (Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(activeColor, m.Colors.white, .18)!,
                  activeColor,
                ],
              ).createShader(rect)),
    );
  }
  canvas.restore();
  canvas.drawRRect(
    body.deflate(.5),
    Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = opaque ? 1.5 : 1,
  );
}

class _LuminaSliderLens extends m.SliderComponentShape {
  const _LuminaSliderLens({
    required this.opaque,
    required this.reduced,
    required this.scale,
    required this.outline,
  });
  final bool opaque, reduced;
  final double scale;
  final Color outline;
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size(30 * scale, 26 * scale);
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required m.SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) => _paintLuminaLens(
    context.canvas,
    center,
    sliderTheme,
    enabled: enableAnimation.value,
    pressure: reduced ? 0 : activationAnimation.value,
    opaque: opaque,
    scale: scale,
    outline: outline,
  );
}

class _LuminaRangeLens extends m.RangeSliderThumbShape {
  const _LuminaRangeLens({
    required this.opaque,
    required this.reduced,
    required this.scale,
    required this.outline,
  });
  final bool opaque, reduced;
  final double scale;
  final Color outline;
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size(30 * scale, 26 * scale);
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool isOnTop = false,
    TextDirection textDirection = TextDirection.ltr,
    required m.SliderThemeData sliderTheme,
    m.Thumb thumb = m.Thumb.start,
    bool isPressed = false,
  }) => _paintLuminaLens(
    context.canvas,
    center,
    sliderTheme,
    enabled: enableAnimation.value,
    pressure: reduced ? 0 : activationAnimation.value,
    opaque: opaque,
    scale: scale,
    outline: outline,
  );
}

class _LuminaSliderTrack extends m.RoundedRectSliderTrackShape {
  const _LuminaSliderTrack({required this.opaque, required this.outline});
  final bool opaque;
  final Color outline;
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required m.SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final active = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(rect.left, rect.top, thumbCenter.dx, rect.bottom)
        : Rect.fromLTRB(thumbCenter.dx, rect.top, rect.right, rect.bottom);
    _paintLuminaTrack(
      context.canvas,
      rect,
      active,
      sliderTheme,
      enableAnimation.value,
      opaque,
      outline,
    );
  }
}

class _LuminaRangeTrack extends m.RoundedRectRangeSliderTrackShape {
  const _LuminaRangeTrack({required this.opaque, required this.outline});
  final bool opaque;
  final Color outline;
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required m.SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset startThumbCenter,
    required Offset endThumbCenter,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final left = textDirection == TextDirection.ltr
        ? startThumbCenter
        : endThumbCenter;
    final right = textDirection == TextDirection.ltr
        ? endThumbCenter
        : startThumbCenter;
    _paintLuminaTrack(
      context.canvas,
      rect,
      Rect.fromLTRB(left.dx, rect.top, right.dx, rect.bottom),
      sliderTheme,
      enableAnimation.value,
      opaque,
      outline,
    );
  }
}

class _LuminaSliderValue extends m.SliderComponentShape {
  const _LuminaSliderValue({required this.opaque});
  final bool opaque;
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(40, 32);
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required m.SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    if (activationAnimation.value <= 0) return;
    final width = labelPainter.width + 24;
    final height = labelPainter.height + 16;
    final global = parentBox.localToGlobal(center);
    final safeX = global.dx.clamp(
      width / 2 + 8,
      (sizeWithOverflow.width - width / 2 - 8).clamp(
        width / 2 + 8,
        double.infinity,
      ),
    );
    final bubble = Rect.fromCenter(
      center: Offset(
        center.dx + safeX - global.dx,
        center.dy - 28 - height / 2,
      ),
      width: width,
      height: height,
    );
    final body = RRect.fromRectAndRadius(bubble, const Radius.circular(14));
    context.canvas.drawRRect(
      body,
      Paint()..color = sliderTheme.valueIndicatorColor!,
    );
    context.canvas.drawRRect(
      body.deflate(.5),
      Paint()
        ..color = sliderTheme.valueIndicatorStrokeColor!
        ..style = PaintingStyle.stroke
        ..strokeWidth = opaque ? 1.5 : 1,
    );
    labelPainter.paint(
      context.canvas,
      bubble.center - Offset(labelPainter.width / 2, labelPainter.height / 2),
    );
  }
}
