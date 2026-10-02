part of 'lumina_catalog.dart';

/// Floating actions share the same glass, focus ring and press response as
/// regular Lumina controls. No Scaffold or Material ancestor is required.
class LuminaFloatingActionButton extends StatelessWidget {
  const LuminaFloatingActionButton({
    required this.onPressed,
    required this.icon,
    this.label,
    this.tooltip,
    super.key,
  });
  final VoidCallback? onPressed;
  final Widget icon;
  final Widget? label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    Widget action = MergeSemantics(
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: Opacity(
          opacity: onPressed == null ? .45 : 1,
          child: LuminaSurface(
            glass: true,
            depth: LuminaSurfaceDepth.raised,
            color: theme.colors.accentSoft,
            radius: label == null ? 20 : LuminaControlSize.capsuleRadius,
            onTap: onPressed,
            padding: EdgeInsets.symmetric(
              horizontal: label == null ? 16 : 20,
              vertical: 16,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              child: DefaultTextStyle(
                style: theme.textTheme.labelMedium,
                child: m.IconTheme(
                  data: m.IconThemeData(color: theme.colors.ink),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      icon,
                      if (label != null) ...[
                        const SizedBox(width: 12),
                        Flexible(child: label!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      action = LuminaTooltip(message: tooltip!, child: action);
    }
    return action;
  }
}

enum LuminaButtonVariant { filled, tonal, elevated, outlined, text }

/// Material-compatible emphasis levels rendered with Lumina's own surfaces.
class LuminaMaterialButton extends StatelessWidget {
  const LuminaMaterialButton({
    required this.child,
    required this.onPressed,
    this.variant = LuminaButtonVariant.filled,
    super.key,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final LuminaButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final textOnly = variant == LuminaButtonVariant.text;
    final outlined = variant == LuminaButtonVariant.outlined;
    Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 28),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    );
    if (outlined) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: theme.colors.accent),
          borderRadius: BorderRadius.circular(LuminaControlSize.capsuleRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: content,
        ),
      );
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: Opacity(
          opacity: onPressed == null ? .45 : 1,
          child: LuminaSurface(
            glass: !textOnly,
            depth: variant == LuminaButtonVariant.elevated
                ? LuminaSurfaceDepth.raised
                : LuminaSurfaceDepth.normal,
            color: switch (variant) {
              LuminaButtonVariant.filled => theme.colors.accentSoft,
              LuminaButtonVariant.tonal => theme.colors.recessedSurface,
              LuminaButtonVariant.elevated => theme.colors.raisedSurface,
              LuminaButtonVariant.outlined => theme.colors.surface,
              LuminaButtonVariant.text => const Color(0x00000000),
            },
            radius: LuminaControlSize.capsuleRadius,
            onTap: onPressed,
            padding: outlined
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: DefaultTextStyle(
              style: theme.textTheme.labelMedium.copyWith(
                color: textOnly ? theme.colors.accent : theme.colors.ink,
              ),
              child: m.IconTheme(
                data: m.IconThemeData(color: theme.colors.ink),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LuminaBadge extends StatelessWidget {
  const LuminaBadge({required this.child, this.label, super.key});
  final Widget child;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        PositionedDirectional(
          top: -4,
          end: -4,
          child: Semantics(
            label: label,
            child: ExcludeSemantics(
              child: LuminaSurface(
                radius: LuminaControlSize.capsuleRadius,
                glass: true,
                color: theme.colors.accentSoft,
                padding: label == null
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                child: label == null
                    ? const SizedBox.square(dimension: 2)
                    : Text(
                        label!,
                        style: theme.textTheme.labelSmall.copyWith(
                          color: theme.colors.ink,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class LuminaLinearProgress extends StatefulWidget {
  const LuminaLinearProgress({this.value, super.key})
    : assert(value == null || (value >= 0 && value <= 1));
  final double? value;

  @override
  State<LuminaLinearProgress> createState() => _LuminaLinearProgressState();
}

class _LuminaLinearProgressState extends State<LuminaLinearProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  void _syncAnimation() {
    if (widget.value == null &&
        !LuminaTheme.motionReducedOf(context) &&
        TickerMode.valuesOf(context).enabled) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(LuminaLinearProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final reduced = LuminaTheme.motionReducedOf(context);
    return Semantics(
      label: LuminaLocalizations.of(context).loading,
      value: widget.value == null ? null : '${(widget.value! * 100).round()}%',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : 200.0;
          return SizedBox(
            width: width,
            height: 10,
            child: LuminaSurface(
              radius: 100,
              padding: EdgeInsets.zero,
              color: theme.colors.recessedSurface,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(100),
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final fraction = widget.value ?? .28;
                    final offset = widget.value == null && !reduced
                        ? _controller.value * (width + width * fraction) -
                              width * fraction
                        : 0.0;
                    return Stack(
                      children: [
                        PositionedDirectional(
                          start: offset,
                          top: 0,
                          bottom: 0,
                          child: AnimatedContainer(
                            duration: reduced
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            width: math.max(0, width * fraction),
                            child: LuminaSurface(
                              glass: true,
                              color: theme.colors.accent,
                              radius: 100,
                              padding: EdgeInsets.zero,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class LuminaDivider extends StatelessWidget {
  const LuminaDivider({this.vertical = false, super.key});
  final bool vertical;

  @override
  Widget build(BuildContext context) => Padding(
    padding: vertical
        ? const EdgeInsets.symmetric(horizontal: 8)
        : const EdgeInsets.symmetric(vertical: 8),
    child: SizedBox(
      width: vertical ? 1 : null,
      height: vertical ? null : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: LuminaTheme.of(context).colors.outline,
        ),
      ),
    ),
  );
}
