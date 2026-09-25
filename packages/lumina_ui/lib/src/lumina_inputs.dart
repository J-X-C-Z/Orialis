part of 'design_components.dart';

class LuminaTextField extends StatefulWidget {
  const LuminaTextField({
    required this.controller,
    this.label,
    this.hint,
    this.hintText,
    this.maxLines = 1,
    this.minLines,
    this.obscureText = false,
    this.onChanged,
    this.keyboardType,
    this.autofocus = false,
    this.readOnly = false,
    this.enabled = true,
    this.onTap,
    this.onSubmitted,
    this.focusNode,
    this.maxLength,
    this.textInputAction,
    super.key,
  });
  final TextEditingController controller;
  final String? label, hint, hintText;
  final int? maxLines, minLines, maxLength;
  final bool obscureText, autofocus, readOnly, enabled;
  final ValueChanged<String>? onChanged, onSubmitted;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  @override
  State<LuminaTextField> createState() => _LuminaTextFieldState();
}

class _LuminaTextFieldState extends State<LuminaTextField> {
  late final FocusNode ownFocus = FocusNode();
  FocusNode get focus => widget.focusNode ?? ownFocus;
  @override
  void dispose() {
    ownFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: LuminaTheme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
        ],
        ListenableBuilder(
          listenable: Listenable.merge([focus, widget.controller]),
          builder: (context, _) => GestureDetector(
            onTap: widget.enabled
                ? () {
                    focus.requestFocus();
                    widget.onTap?.call();
                  }
                : null,
            child: AnimatedContainer(
              duration: LuminaTheme.motionReducedOf(context)
                  ? Duration.zero
                  : LuminaMotion.fast,
              constraints: const BoxConstraints(
                minHeight: LuminaControlSize.minimum,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: focus.hasFocus ? colors.accent : colors.outline,
                  width: focus.hasFocus ? 1.5 : 1,
                ),
              ),
              child: Stack(
                children: [
                  if (widget.controller.text.isEmpty)
                    IgnorePointer(
                      child: Text(
                        widget.hintText ?? widget.hint ?? '',
                        style: LuminaTheme.of(context).textTheme.bodyMedium
                            .copyWith(color: colors.muted),
                      ),
                    ),
                  Semantics(
                    textField: true,
                    label: widget.label,
                    enabled: widget.enabled,
                    child: ExcludeFocus(
                      excluding: !widget.enabled,
                      child: IgnorePointer(
                        ignoring: !widget.enabled,
                        child: EditableText(
                          controller: widget.controller,
                          focusNode: focus,
                          style: LuminaTheme.of(context).textTheme.bodyMedium,
                          cursorColor: colors.accent,
                          backgroundCursorColor: colors.outline,
                          selectionColor: colors.accentSoft,
                          autofocus: widget.autofocus,
                          readOnly: widget.readOnly || !widget.enabled,
                          obscureText: widget.obscureText,
                          maxLines: widget.obscureText ? 1 : widget.maxLines,
                          minLines: widget.minLines,
                          keyboardType: widget.keyboardType,
                          textInputAction: widget.textInputAction,
                          onChanged: widget.onChanged,
                          onSubmitted: widget.onSubmitted,
                          inputFormatters: widget.maxLength == null
                              ? null
                              : [
                                  LengthLimitingTextInputFormatter(
                                    widget.maxLength,
                                  ),
                                ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class LuminaCheck extends StatelessWidget {
  const LuminaCheck({required this.value, required this.onChanged, super.key});
  final bool value;
  final FutureOr<void> Function(bool)? onChanged;
  @override
  Widget build(BuildContext context) => Semantics(
    checked: value,
    enabled: onChanged != null,
    child: LuminaIconButton(
      tooltip: value
          ? LuminaLocalizations.of(context).deselect
          : LuminaLocalizations.of(context).select,
      onPressed: onChanged == null
          ? null
          : () {
              final scope = context
                  .getInheritedWidgetOfExactType<_CompletionScope>();
              if (scope != null) {
                unawaited(scope.run(() => onChanged!(!value), context, !value));
              } else {
                onChanged!(!value);
              }
            },
      icon: AnimatedContainer(
        duration: LuminaTheme.motionReducedOf(context)
            ? Duration.zero
            : LuminaMotion.fast,
        curve: luminaEaseOut,
        width: LuminaIconSize.control,
        height: LuminaIconSize.control,
        decoration: BoxDecoration(
          color: value
              ? LuminaTheme.of(context).colors.accentSoft
              : const Color(0x00000000),
          border: Border.all(color: LuminaTheme.of(context).colors.muted),
          shape: BoxShape.circle,
        ),
        child: AnimatedOpacity(
          opacity: value ? 1 : 0,
          duration: LuminaTheme.motionReducedOf(context)
              ? Duration.zero
              : LuminaMotion.fast,
          curve: luminaEaseOut,
          child: const LuminaIcon(LuminaIcons.check, size: 18),
        ),
      ),
    ),
  );
}

class LuminaSwitch extends StatelessWidget {
  const LuminaSwitch({required this.value, required this.onChanged, super.key});
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            width: 56,
            height: 32,
            child: LuminaSlidingSelection(
              index: value ? 1 : 0,
              count: 2,
              confirmed: value,
              onDragEnd: onChanged == null
                  ? null
                  : (index) => onChanged!(index == 1),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// One persistent lens: retargeting retains position and velocity. Only this
/// small overlay ticks; labels and page content stay outside the animation.
class LuminaSlidingSelection extends StatefulWidget {
  const LuminaSlidingSelection({
    required this.index,
    required this.count,
    required this.child,
    this.longTravel = false,
    this.confirmed = false,
    this.onDragEnd,
    super.key,
  }) : assert(count > 0),
       assert(index >= 0 && index < count);
  final int index, count;
  final bool longTravel;

  /// Gives an active binary control a visible confirmation inside its lens.
  final bool confirmed;

  /// Optional long-press scrub. Navigation commits only when the finger lifts.
  final ValueChanged<int>? onDragEnd;
  final Widget child;
  @override
  State<LuminaSlidingSelection> createState() => _LuminaSlidingSelectionState();
}

class _LuminaSlidingSelectionState extends State<LuminaSlidingSelection>
    with SingleTickerProviderStateMixin {
  late final LuminaSpring position = LuminaSpring(
    vsync: this,
    value: widget.index.toDouble(),
  );
  bool _dragging = false;
  double _grabOffset = 0;

  void _startDrag(LongPressStartDetails details) {
    final width = (context.size?.width ?? 0) / widget.count;
    if (width <= 0) return;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final selected = rtl ? widget.count - 1 - position.value : position.value;
    final slot = details.localPosition.dx / width;
    if ((slot - selected - .5).abs() > .5) return;
    _dragging = true;
    position.stop();
    _grabOffset = details.localPosition.dx - (selected + .5) * width;
    unawaited(HapticFeedback.selectionClick());
  }

  void _moveDrag(Offset local) {
    if (!_dragging) return;
    final width = (context.size?.width ?? 0) / widget.count;
    if (width <= 0) return;
    final raw = (local.dx - _grabOffset) / width - .5;
    final last = (widget.count - 1).toDouble();
    final damped = raw < 0
        ? (raw * .22).clamp(-.18, 0.0)
        : raw > last
        ? last + ((raw - last) * .22).clamp(0.0, .18)
        : raw;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    position.value = rtl ? last - damped : damped;
  }

  void _endDrag(Offset local) {
    if (!_dragging) return;
    _moveDrag(local);
    _dragging = false;
    final target = position.value.round().clamp(0, widget.count - 1);
    position.settleNavigation(
      target.toDouble(),
      reducedMotion: LuminaTheme.motionReducedOf(context),
    );
    if (target != widget.index) widget.onDragEnd?.call(target);
  }

  void _cancelDrag() {
    if (!_dragging) return;
    _dragging = false;
    position.settleNavigation(
      widget.index.toDouble(),
      reducedMotion: LuminaTheme.motionReducedOf(context),
    );
  }

  @override
  void didUpdateWidget(LuminaSlidingSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index || oldWidget.count != widget.count) {
      _dragging = false;
      final reduced =
          LuminaTheme.motionReducedOf(context) ||
          oldWidget.count != widget.count;
      if (widget.longTravel) {
        position.settleNavigation(
          widget.index.toDouble(),
          reducedMotion: reduced,
        );
      } else {
        position.settle(widget.index.toDouble(), reducedMotion: reduced);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (LuminaTheme.motionReducedOf(context)) {
      position.settle(widget.index.toDouble(), reducedMotion: true);
    }
  }

  @override
  void dispose() {
    position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: _LuminaSelectionWell()),
      if (widget.onDragEnd == null)
        widget.child
      else
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart: _startDrag,
          onLongPressMoveUpdate: (details) => _moveDrag(details.localPosition),
          onLongPressEnd: (details) => _endDrag(details.localPosition),
          onLongPressCancel: _cancelDrag,
          child: widget.child,
        ),
      Positioned.fill(
        child: IgnorePointer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth / widget.count;
              final rtl = Directionality.of(context) == TextDirection.rtl;
              return AnimatedBuilder(
                animation: position,
                child: RawMagnifier(
                  size: Size(width, constraints.maxHeight),
                  magnificationScale:
                      LuminaTheme.of(context).reduceTransparency ||
                          MediaQuery.highContrastOf(context)
                      ? 1
                      : 1.08,
                  decoration: const MagnifierDecoration(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(
                        Radius.circular(LuminaControlSize.capsuleRadius),
                      ),
                    ),
                  ),
                  child: CustomPaint(
                    key: const ValueKey('lumina-selection-lens'),
                    painter: _LuminaMaterial(
                      colors: LuminaTheme.of(context).colors,
                      tint: widget.confirmed
                          ? LuminaTheme.of(context).colors.accent
                                .withValues(alpha: .62)
                          : LuminaTheme.of(context).colors.accentSoft
                                .withValues(alpha: .14),
                      radius: LuminaControlSize.capsuleRadius,
                      depth: LuminaSurfaceDepth.raised,
                      shoulder: false,
                      contrast: MediaQuery.highContrastOf(context),
                      focused: false,
                      pressed: false,
                      glass: true,
                      diffuseGlass: false,
                      cheapShadow: true,
                    ),
                    child: widget.confirmed
                        ? Center(
                            child: LuminaIcon(
                              LuminaIcons.check,
                              size: 16,
                              color:
                                  MediaQuery.highContrastOf(context) ||
                                      LuminaTheme.of(context).reduceTransparency
                                  ? LuminaTheme.of(context).colors.ink
                                  : LuminaTheme.of(context).colors.surface,
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
                builder: (context, child) {
                  final x = position.value.clamp(
                    -.18,
                    widget.count - 1.0 + .18,
                  );
                  final stretch = LuminaTheme.motionReducedOf(context)
                      ? 0.0
                      : (position.velocity.abs() * .004).clamp(0.0, .035);
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Transform.translate(
                      offset: Offset(
                        (rtl ? widget.count - 1 - x : x) * width,
                        0,
                      ),
                      child: Transform.scale(
                        scaleX: 1 + stretch,
                        scaleY: 1 - stretch * .5,
                        child: SizedBox(
                          width: width,
                          height: constraints.maxHeight,
                          child: child,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    ],
  );
}

/// One clipped, stationary glass well per sliding control. The small fixed
/// backdrop filter and inner blur are isolated from the moving lens painter.
class _LuminaSelectionWell extends StatelessWidget {
  const _LuminaSelectionWell();

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final opaque =
        theme.reduceTransparency || MediaQuery.highContrastOf(context);
    final config = theme.highPerformanceMode
        ? const LuminaBlurConfig(level: LuminaBlurLevel.blurS)
        : const LuminaBlurConfig(level: LuminaBlurLevel.blurM);
    final filter = opaque ? null : LuminaBlurFilters.forConfig(config);
    return IgnorePointer(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (filter != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(
                  LuminaControlSize.capsuleRadius,
                ),
                child: BackdropFilter(
                  filter: filter,
                  child: const SizedBox.expand(),
                ),
              ),
            CustomPaint(
              key: const ValueKey('lumina-selection-well'),
              painter: _LuminaMaterial(
                colors: theme.colors,
                tint: theme.colors.recessedSurface.withValues(
                  alpha: opaque ? 1 : .72,
                ),
                radius: LuminaControlSize.capsuleRadius,
                depth: LuminaSurfaceDepth.recessed,
                shoulder: false,
                contrast: MediaQuery.highContrastOf(context),
                focused: false,
                pressed: false,
                glass: !opaque,
                diffuseGlass: true,
                cheapShadow: false,
                blurCompensation: opaque ? 0 : config.compensation,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LuminaSegmented<T> extends StatelessWidget {
  const LuminaSegmented({
    required this.items,
    required this.value,
    required this.onChanged,
    super.key,
  });
  final Map<T, String> items;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) => LuminaSurface(
    depth: LuminaSurfaceDepth.raised,
    padding: const EdgeInsets.all(4),
    radius: LuminaControlSize.capsuleRadius,
    child: LuminaSlidingSelection(
      index: items.keys.toList().indexOf(value).clamp(0, items.length - 1),
      count: items.length,
      onDragEnd: (index) => onChanged(items.keys.elementAt(index)),
      child: Row(
        children: items.entries
            .map(
              (e) => Expanded(
                child: Semantics(
                  selected: e.key == value,
                  child: LuminaSurface(
                    color: const Color(0x00000000),
                    onTap: () => onChanged(e.key),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 11,
                    ),
                    radius: LuminaControlSize.capsuleRadius,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 26),
                      child: Center(
                        child: Text(
                          e.value,
                          textAlign: TextAlign.center,
                          style: LuminaTheme.of(context).textTheme.labelMedium,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    ),
  );
}

/// A discrete value control built from the same inset glass track and lens.
/// Taps jump to a step; holding the lens lets the user scrub before release.
class LuminaValueSlider extends StatelessWidget {
  const LuminaValueSlider({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions = 10,
    super.key,
  }) : assert(max > min),
       assert(divisions > 0);

  final double value, min, max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = (((value - min) / (max - min)) * divisions).round().clamp(
      0,
      divisions,
    );
    void choose(int index) =>
        onChanged?.call(min + (max - min) * index / divisions);
    String label(int index) =>
        (min + (max - min) * index / divisions).toStringAsFixed(2);
    return Semantics(
      value: label(selected),
      increasedValue: label((selected + 1).clamp(0, divisions)),
      decreasedValue: label((selected - 1).clamp(0, divisions)),
      enabled: onChanged != null,
      onIncrease: onChanged == null
          ? null
          : () => choose((selected + 1).clamp(0, divisions)),
      onDecrease: onChanged == null
          ? null
          : () => choose((selected - 1).clamp(0, divisions)),
      child: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: onChanged == null
              ? null
              : (details) {
                  final width = constraints.maxWidth;
                  if (width <= 0) return;
                  final fraction = (details.localPosition.dx / width).clamp(
                    0.0,
                    1.0,
                  );
                  final logical =
                      Directionality.of(context) == TextDirection.rtl
                      ? 1 - fraction
                      : fraction;
                  choose((logical * divisions).round());
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: SizedBox(
              height: 28,
              child: LuminaSlidingSelection(
                index: selected,
                count: divisions + 1,
                onDragEnd: onChanged == null ? null : choose,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
