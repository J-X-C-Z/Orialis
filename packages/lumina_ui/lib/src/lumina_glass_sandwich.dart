part of 'design_components.dart';

/// The recessed backing and frost sit below the label, never blur the label.
class LuminaGlassWell extends StatelessWidget {
  const LuminaGlassWell({
    this.child = const SizedBox.expand(),
    this.radius = LuminaControlSize.capsuleRadius,
    this.tint,
    this.focused = false,
    super.key,
  });
  final Widget child;
  final double radius;
  final Color? tint;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final opaque =
        theme.reduceTransparency || MediaQuery.highContrastOf(context);
    final backing = Color.lerp(
      theme.colors.surface,
      tint ?? theme.colors.surface,
      .32,
    )!;
    Widget frost = ColoredBox(
      color: backing.withValues(alpha: opaque ? 1 : .16),
    );
    if (!opaque && !theme.highPerformanceMode) {
      // Normal mode softens the well's own gradient. The performance path
      // keeps the painted frost without a per-control backdrop sampling pass.
      frost = BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: theme.highPerformanceMode ? 2 : 4,
          sigmaY: theme.highPerformanceMode ? 2 : 4,
        ),
        child: frost,
      );
    }
    return CustomPaint(
      painter: _LuminaMaterial(
        colors: theme.colors,
        tint: backing,
        radius: radius,
        depth: LuminaSurfaceDepth.recessed,
        shoulder: false,
        contrast: MediaQuery.highContrastOf(context),
        focused: focused,
        pressed: false,
        neumorphic: true,
      ),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: frost,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Paint-only cover; pointer, focus and semantics stay on the real control.
class LuminaGlassCoat extends StatelessWidget {
  const LuminaGlassCoat({
    this.radius = LuminaControlSize.capsuleRadius,
    this.pressed = false,
    super.key,
  });
  final double radius;
  final bool pressed;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    if (theme.reduceTransparency || MediaQuery.highContrastOf(context)) {
      return const SizedBox.expand();
    }
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: CustomPaint(
          painter: _LuminaMaterial(
            colors: theme.colors,
            tint: theme.colors.accentSoft.withValues(alpha: .12),
            radius: math.max(0, radius - 3),
            depth: LuminaSurfaceDepth.recessed,
            shoulder: false,
            contrast: false,
            focused: false,
            pressed: pressed,
            liquidGlass: true,
            embeddedGlass: true,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// One geometry for well, content and clear cover keeps the sandwich aligned.
class LuminaGlassSandwich extends StatelessWidget {
  const LuminaGlassSandwich({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = LuminaControlSize.capsuleRadius,
    this.tint,
    this.focused = false,
    this.pressed = false,
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;
  final bool focused, pressed;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      LuminaGlassWell(
        radius: radius,
        tint: tint,
        focused: focused,
        child: Padding(padding: padding, child: child),
      ),
      Positioned.fill(
        child: LuminaGlassCoat(radius: radius, pressed: pressed),
      ),
    ],
  );
}
