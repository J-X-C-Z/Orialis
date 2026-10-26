import 'dart:async';
import 'dart:ui' as ui;

import 'package:lumina_ui/lumina_ui.dart';

/// A thin glass rim, separated from the caller's opaque neumorphic surface.
class OrialisNavigationGlassFrame extends StatelessWidget {
  const OrialisNavigationGlassFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return CustomPaint(
      painter: _NavigationGlassPaint(
        colors: theme.colors,
        opaque: theme.reduceTransparency || MediaQuery.highContrastOf(context),
        frame: true,
      ),
      child: Padding(padding: const EdgeInsets.all(6), child: child),
    );
  }
}

/// Filter a bounded navigation image, never an ambiguously sized backdrop.
class OrialisNavigationGlassLens extends StatefulWidget {
  const OrialisNavigationGlassLens({
    required this.child,
    required this.position,
    required this.count,
    super.key,
  });
  final Widget child;
  final double position;
  final int count;

  @override
  State<OrialisNavigationGlassLens> createState() =>
      _OrialisNavigationGlassLensState();
}

class _OrialisNavigationGlassLensState
    extends State<OrialisNavigationGlassLens> {
  static Future<ui.FragmentProgram?>? _program;
  ui.FragmentShader? _shader;
  bool _requested = false;

  static Future<ui.FragmentProgram?> _loadProgram() async {
    try {
      return await ui.FragmentProgram.fromAsset('shaders/navigation_lens.frag');
    } catch (error, stack) {
      debugPrint(
        'Navigation lens shader failed; using clear-rim fallback: '
        '$error\n$stack',
      );
      return null;
    }
  }

  Future<void> _loadShader() async {
    final program = await (_program ??= _loadProgram());
    if (!mounted || program == null) return;
    // Each mounted lens owns its instance; only the immutable program is shared.
    final shader = program.fragmentShader();
    setState(() => _shader = shader);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = LuminaTheme.of(context);
    if (_requested ||
        theme.reduceTransparency ||
        MediaQuery.highContrastOf(context)) {
      return;
    }
    _requested = true;
    if (ui.ImageFilter.isShaderFilterSupported) {
      unawaited(_loadShader());
    }
    // Skia keeps the clear rim and engraving; curved refraction needs Impeller.
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
        final rtl = Directionality.of(context) == TextDirection.rtl;
        final index = widget.position.clamp(0.0, widget.count - 1.0);
        final physical = rtl ? widget.count - 1 - index : index;
        final fraction = (physical + .5) / widget.count;
        final shader = _shader;
        final filtered =
            !opaque && shader != null && ui.ImageFilter.isShaderFilterSupported;
        if (filtered) {
          // The child is clipped before sampling: input coordinates belong to
          // this navigation image, not the surrounding page or global screen.
          shader
            ..setFloat(2, MediaQuery.devicePixelRatioOf(context))
            ..setFloat(3, theme.highPerformanceMode ? 1 : 0)
            ..setFloat(4, fraction)
            ..setFloat(5, widget.count.toDouble());
        }
        return Stack(
          fit: StackFit.passthrough,
          children: [
            ImageFiltered(
              enabled: filtered,
              imageFilter: filtered
                  ? ui.ImageFilter.shader(shader)
                  : ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0),
              child: ClipRect(child: widget.child),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Transform.translate(
                      offset: Offset(
                        physical * constraints.maxWidth / widget.count,
                        0,
                      ),
                      child: SizedBox(
                        key: const ValueKey('nav-glass-slider'),
                        width: constraints.maxWidth / widget.count,
                        height: constraints.maxHeight,
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
    final rimWidth = frame ? 2.6 : 1.2;
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(outer)
      ..addRRect(outer.deflate(rimWidth));
    if (opaque) {
      canvas.drawPath(ring, Paint()..color = colors.surface);
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
    final refracted = Color.lerp(colors.surface, colors.accent, .20)!;
    canvas.drawPath(
      ring,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          [
            light.withValues(alpha: colors.toneValue(.32, .14)),
            refracted.withValues(alpha: .035),
            refracted.withValues(alpha: colors.toneValue(.24, .36)),
          ],
          [0, .48, 1],
        ),
    );
    if (!frame) {
      // The body is clear; only the lower edge catches a faint wash of light.
      canvas.drawRRect(
        outer,
        Paint()
          ..shader = ui.Gradient.linear(
            rect.topCenter,
            rect.bottomCenter,
            [
              light.withValues(alpha: .025),
              light.withValues(alpha: 0),
              refracted.withValues(alpha: colors.toneValue(.055, .09)),
            ],
            [0, .45, 1],
          ),
      );
    }
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.05
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          [
            light.withValues(alpha: colors.toneValue(.82, .42)),
            light.withValues(alpha: .04),
            refracted.withValues(alpha: colors.toneValue(.40, .58)),
            light.withValues(alpha: colors.toneValue(.46, .24)),
          ],
          [0, .45, .78, 1],
        ),
    );
    canvas.drawRRect(
      outer.deflate(rimWidth),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .65
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
          colors.ink.withValues(alpha: colors.toneValue(.13, .25)),
          light.withValues(alpha: colors.toneValue(.36, .16)),
        ]),
    );
  }

  @override
  bool shouldRepaint(_NavigationGlassPaint oldDelegate) =>
      colors != oldDelegate.colors ||
      opaque != oldDelegate.opaque ||
      frame != oldDelegate.frame;
}
