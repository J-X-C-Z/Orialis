import 'dart:ui' as ui;

import 'package:lumina_ui/lumina_ui.dart';

/// A frosted glass housing, without a raised clay bevel.
class OrialisNavigationGlassFrame extends StatelessWidget {
  const OrialisNavigationGlassFrame({required this.child, super.key});

  final Widget child;

  static const innerInsets = EdgeInsets.symmetric(horizontal: 9, vertical: 7);
  static const surfaceDepth = 4.0;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final opaque =
        theme.reduceTransparency || MediaQuery.highContrastOf(context);
    return ListenableBuilder(
      listenable: LuminaBlurPolicy.instance.chromeListenable,
      builder: (context, _) {
        final sigma = theme.highPerformanceMode ? 3.5 : 5.5;
        final blur = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(1000),
                  child: opaque
                      ? ColoredBox(color: theme.colors.surface)
                      : BackdropFilter(
                          filter: blur,
                          child: ColoredBox(
                            color: theme.colors.surface.withValues(alpha: .48),
                          ),
                        ),
                ),
              ),
            ),
            CustomPaint(
              foregroundPainter: _NavigationGlassPaint(
                colors: theme.colors,
                opaque: opaque,
                frame: true,
              ),
              child: Padding(padding: innerInsets, child: child),
            ),
          ],
        );
      },
    );
  }
}

/// Refraction samples the live navigation labels, never a screenshot.
class OrialisNavigationGlassLens extends StatefulWidget {
  const OrialisNavigationGlassLens({
    required this.child,
    required this.position,
    required this.count,
    this.shaderRefraction = true,
    super.key,
  });
  final Widget child;
  final double position;
  final int count;
  final bool shaderRefraction;

  @override
  State<OrialisNavigationGlassLens> createState() =>
      _NavigationGlassLensState();
}

class _NavigationGlassLensState extends State<OrialisNavigationGlassLens> {
  static Future<ui.FragmentProgram>? _program;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (widget.shaderRefraction && ui.ImageFilter.isShaderFilterSupported) {
      _loadShader();
    }
  }

  @override
  void didUpdateWidget(OrialisNavigationGlassLens oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.shaderRefraction &&
        widget.shaderRefraction &&
        _shader == null &&
        ui.ImageFilter.isShaderFilterSupported) {
      _loadShader();
    }
  }

  Future<void> _loadShader() async {
    final program = await (_program ??= ui.FragmentProgram.fromAsset(
      'shaders/navigation_lens.frag',
    ));
    if (mounted) setState(() => _shader = program.fragmentShader());
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final opaque =
        theme.reduceTransparency || MediaQuery.highContrastOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = widget.count;
        final index = widget.position.clamp(0.0, count - 1.0);
        final physical = Directionality.of(context) == TextDirection.rtl
            ? count - 1 - index
            : index;
        final trackPadding = 3 * theme.data.spacingScale;
        final slotWidth = (constraints.maxWidth - 2 * trackPadding) / count;
        // Nonzero fill preserves the full sampling bounds; padding alone does not.
        final content = ColoredBox(
          key: const ValueKey('nav-glass-sampling-region'),
          color: theme.colors.surface.withValues(alpha: 1 / 255),
          child: Padding(
            padding: EdgeInsets.all(trackPadding),
            child: widget.child,
          ),
        );
        final shader = opaque || !widget.shaderRefraction ? null : _shader;
        if (shader != null) {
          shader
            ..setFloat(2, MediaQuery.devicePixelRatioOf(context))
            ..setFloat(3, theme.highPerformanceMode ? 1 : 0)
            ..setFloat(4, (physical + .5) / count)
            ..setFloat(5, count.toDouble())
            ..setFloat(
              6,
              trackPadding * MediaQuery.devicePixelRatioOf(context),
            );
        }
        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            if (shader != null)
              ImageFiltered(
                imageFilter: ui.ImageFilter.shader(shader),
                child: content,
              )
            else
              content,
            Positioned(
              left: physical * slotWidth,
              width: slotWidth + 2 * trackPadding,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: SizedBox(
                    key: const ValueKey('nav-glass-slider'),
                    child: opaque
                        ? const SizedBox.expand()
                        : CustomPaint(
                            painter: _NavigationGlassPaint(
                              colors: theme.colors,
                              opaque: false,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NavigationGlassPaint extends CustomPainter {
  const _NavigationGlassPaint({
    required this.colors,
    required this.opaque,
    this.frame = false,
  });

  final LuminaColors colors;
  final bool opaque;
  final bool frame;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(.65);
    if (rect.isEmpty) return;
    final outer = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.shortestSide / 2),
    );
    final outline = Path()..addRRect(outer);
    final innerRect = Rect.fromLTRB(
      rect.left + OrialisNavigationGlassFrame.innerInsets.left,
      rect.top + OrialisNavigationGlassFrame.innerInsets.top,
      rect.right - OrialisNavigationGlassFrame.innerInsets.right,
      rect.bottom - OrialisNavigationGlassFrame.innerInsets.bottom,
    );
    final housing = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(outer)
      ..addRRect(
        RRect.fromRectAndRadius(
          innerRect,
          Radius.circular(innerRect.height / 2),
        ),
      );
    final material = frame ? housing : outline;
    if (opaque) {
      canvas.drawPath(material, Paint()..color = colors.surface);
      canvas.drawRRect(
        outer,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = colors.muted,
      );
      return;
    }
    const light = Color(0xFFFFFFFF);
    if (frame) {
      canvas.drawRRect(
        outer,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
            light.withValues(alpha: colors.toneValue(.46, .25)),
            colors.muted.withValues(alpha: .12),
          ]),
      );
      return;
    }
    final glass = Color.lerp(colors.surface, colors.accent, .16)!;
    final shade = Color.lerp(colors.surface, const Color(0xFF101D2B), .65)!;
    final depth = OrialisNavigationGlassFrame.surfaceDepth;

    // Housing and lens use the same projected sidewall depth. The lens stays
    // inside the housing opening; raising its surface never enlarges its bounds.
    canvas.drawPath(
      material,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [
            light.withValues(alpha: colors.toneValue(.27, .13)),
            glass.withValues(alpha: frame ? .24 : .08),
            glass.withValues(alpha: frame ? .36 : .16),
          ],
          [0, .45, 1],
        ),
    );
    final faceRect = Rect.fromLTRB(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom - depth,
    );
    final face = RRect.fromRectAndRadius(
      faceRect,
      Radius.circular(faceRect.shortestSide / 2),
    );
    final sidewall = Path.combine(
      PathOperation.difference,
      outline,
      Path()..addRRect(face),
    );
    canvas.save();
    canvas.clipPath(material);
    canvas.drawPath(
      sidewall,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(rect.center.dx, rect.bottom - depth * 1.5),
          rect.bottomCenter,
          [
            glass.withValues(alpha: colors.toneValue(.34, .42)),
            shade.withValues(alpha: colors.toneValue(.30, .54)),
          ],
        ),
    );
    // A broad top bevel replaces nested stroked rings.
    canvas.drawRect(
      Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + depth * 2),
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          Offset(rect.center.dx, rect.top + depth * 2),
          [
            light.withValues(alpha: colors.toneValue(.36, .20)),
            light.withValues(alpha: 0),
          ],
        ),
    );
    canvas.restore();
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          [
            light.withValues(alpha: colors.toneValue(.74, .42)),
            light.withValues(alpha: .025),
            shade.withValues(alpha: colors.toneValue(.22, .38)),
          ],
          [0, .48, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_NavigationGlassPaint oldDelegate) =>
      colors != oldDelegate.colors ||
      opaque != oldDelegate.opaque ||
      frame != oldDelegate.frame;
}
