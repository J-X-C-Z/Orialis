part of 'design_components.dart';

/// One top-left light source across section cards, controls and inset rows.
class _LuminaMaterial extends CustomPainter {
  const _LuminaMaterial({
    required this.colors,
    required this.tint,
    required this.radius,
    required this.depth,
    required this.shoulder,
    this.shoulderWidth,
    required this.contrast,
    required this.focused,
    required this.pressed,
    this.glass = false,
    this.diffuseGlass = false,
    this.cheapShadow = false,
    this.blurCompensation = 0,
  });

  final LuminaColors colors;
  final Color tint;
  final double radius;
  final LuminaSurfaceDepth depth;
  final bool shoulder, contrast, focused, pressed;
  final double? shoulderWidth;
  final bool glass;
  final bool diffuseGlass;
  final bool cheapShadow;

  /// 0–1 — rises as blur level drops so tint + micro-noise + rim replace sigma.
  final double blurCompensation;

  Path _outline(Size size) {
    final w = size.width, h = size.height;
    final r = radius.clamp(0.0, size.shortestSide / 2).toDouble();
    if (!shoulder || w < 160 || h < 64) {
      return Path()..addRRect(RRect.fromLTRBR(0, 0, w, h, Radius.circular(r)));
    }
    final shelf = (shoulderWidth ?? r * 2)
        .clamp(r, math.max(r, w - r - 32))
        .toDouble();
    const drop = 10.0;
    return Path()
      ..moveTo(r, 0)
      ..lineTo(shelf, 0)
      ..cubicTo(shelf + 16, 0, shelf + 16, drop, shelf + 32, drop)
      ..lineTo(w - r, drop)
      ..quadraticBezierTo(w, drop, w, drop + r)
      ..lineTo(w, h - r)
      ..quadraticBezierTo(w, h, w - r, h)
      ..lineTo(r, h)
      ..quadraticBezierTo(0, h, 0, h - r)
      ..lineTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..close();
  }

  // Gradient construction is not free; list scrolling repaints many surfaces
  // with the same tint/radius/size, so keep the last few shader builds around.
  static final Map<String, ui.Gradient> _bodyGradientCache = {};
  static final Map<String, ui.Gradient> _rimGradientCache = {};
  static const int _gradientCacheLimit = 64;
  // One small repeated texture, rather than thousands of points regenerated
  // for every intermediate card height during a fold.
  static final ui.Image _grainImage = _makeGrain();
  static final ui.Shader _grainShader = ui.ImageShader(
    _grainImage,
    TileMode.repeated,
    TileMode.repeated,
    (Matrix4.identity()..scaleByDouble(1 / 3, 1 / 3, 1, 1)).storage,
  );
  static ui.Image _makeGrain() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Rasterize above logical resolution so grain stays fine on dense phones.
    canvas.scale(3);
    final light = Paint()
      ..color = const Color(0x50FFFFFF)
      ..strokeWidth = .55
      ..strokeCap = StrokeCap.round;
    final dark = Paint()
      ..color = const Color(0x10000000)
      ..strokeWidth = .4;
    final points = <Offset>[
      for (var y = 2.0; y < 64; y += 2.3)
        for (var x = 2.0; x < 64; x += 2.3)
          Offset(
            x + math.sin(x * 13 + y * 7) * 1.6,
            y + math.sin(x * 3 + y * 11) * 1.6,
          ),
    ];
    canvas.drawPoints(ui.PointMode.points, points, light);
    canvas.translate(.7, .7);
    canvas.drawPoints(ui.PointMode.points, points, dark);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(192, 192);
    picture.dispose();
    return image;
  }

  static ui.Gradient _cachedGradient(
    Map<String, ui.Gradient> cache,
    String key,
    ui.Gradient Function() make,
  ) {
    final hit = cache.remove(key);
    if (hit != null) {
      cache[key] = hit;
      return hit;
    }
    final created = make();
    if (cache.length >= _gradientCacheLimit) {
      cache.remove(cache.keys.first);
    }
    cache[key] = created;
    return created;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final path = _outline(size), rect = Offset.zero & size;
    final inset = depth == LuminaSurfaceDepth.recessed;
    final light = colors.dark
        ? const Color(0xFF4B5E6D)
        : const Color(0xFFFFFFFF);
    final shade = colors.dark
        ? const Color(0xFF070F18)
        : const Color(0xFFA6B7CD);
    if (!inset && !contrast) {
      canvas.save();
      if (glass) {
        // Keep a translucent control's own shadow outside its glass body.
        canvas.clipPath(
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(rect.inflate(24))
            ..addPath(path, Offset.zero),
        );
      }
      // One drop-shadow blur only; the top-left rim comes from the final
      // gradient stroke so list/control surfaces do not stack two blurs.
      // High-performance mode swaps the blur for a flat offset wash —
      // MaskFilter.blur forces an offscreen layer per surface.
      final shadowPaint = Paint()
        ..color = shade.withValues(
          alpha: glass
              ? .14
              : colors.dark
              ? .28
              : .22,
        );
      if (!cheapShadow) {
        shadowPaint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      }
      canvas.drawPath(path.shift(Offset(2, pressed ? 1 : 5)), shadowPaint);
      if (cheapShadow) {
        canvas.drawPath(
          path.shift(Offset(1, pressed ? 0 : 2)),
          Paint()..color = shade.withValues(alpha: .10),
        );
      }
      canvas.restore();
    }
    if (!inset && !glass && !contrast) {
      // A narrow solid lower edge adds material thickness without another blur.
      canvas.drawPath(
        path.shift(Offset(0, pressed ? 1 : 3)),
        Paint()..color = Color.lerp(tint, shade, colors.dark ? .42 : .24)!,
      );
    }
    final bodyKey =
        '${colors.dark}|$glass|$diffuseGlass|$inset|$contrast|${tint.toARGB32()}|${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)}';
    canvas.drawPath(
      path,
      Paint()
        ..shader = _cachedGradient(_bodyGradientCache, bodyKey, () {
          if (glass) {
            if (diffuseGlass) {
              final frost = Color.lerp(
                tint,
                colors.surface.withValues(alpha: tint.a),
                .52,
              )!;
              return ui.Gradient.linear(
                rect.topLeft,
                rect.bottomRight,
                [
                  Color.lerp(frost, light.withValues(alpha: frost.a), .36)!,
                  frost,
                  Color.lerp(frost, light.withValues(alpha: frost.a), .18)!,
                  light.withValues(alpha: colors.dark ? .09 : .30),
                ],
                [0, .36, .78, 1],
              );
            }
            return ui.Gradient.linear(
              rect.topLeft,
              rect.bottomRight,
              [
                Color.lerp(tint, light.withValues(alpha: .78), .55)!,
                tint.withValues(alpha: tint.a * .65),
                Color.lerp(tint, colors.accent.withValues(alpha: .12), .35)!,
                light.withValues(alpha: colors.dark ? .10 : .42),
              ],
              [0, .40, .74, 1],
            );
          }
          return ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
            Color.lerp(tint, inset ? shade : light, inset ? .10 : .16)!,
            tint,
          ]);
        }),
    );
    canvas.save();
    canvas.clipPath(path);
    if (!glass && !contrast) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = _grainShader
          ..color = Color.fromRGBO(255, 255, 255, colors.dark ? .55 : 1),
      );
      if (!inset) {
        canvas.drawPath(
          path.shift(const Offset(0, 1)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..shader = ui.Gradient.linear(
              rect.topCenter,
              rect.bottomCenter,
              [light.withValues(alpha: .65), light.withValues(alpha: 0)],
              [0, .32],
            ),
        );
      }
    }
    if (glass && !contrast) {
      // A refractive inner rim, not a card's left-hand highlight stripe.
      // Gradient strokes add lens depth without another blur or offscreen layer.
      final rimKey =
          '${colors.dark}|$diffuseGlass|${pressed ? 1 : 0}|${colors.accent.toARGB32()}|${rect.height}';
      final rimShiftKey = '$rimKey|shift';
      canvas.drawPath(
        path.shift(Offset(0, pressed ? 1 : 2.5)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = pressed ? 2 : 3.5
          ..shader = _cachedGradient(_rimGradientCache, rimKey, () {
            return ui.Gradient.linear(
              rect.topCenter,
              rect.bottomCenter,
              [
                light.withValues(alpha: .70),
                light.withValues(alpha: .02),
                colors.accent.withValues(alpha: diffuseGlass ? .07 : .18),
              ],
              [0, .48, 1],
            );
          }),
      );
      canvas.drawPath(
        path.shift(const Offset(0, -1.5)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..shader = _cachedGradient(_rimGradientCache, rimShiftKey, () {
            return ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
              light.withValues(alpha: 0),
              light.withValues(alpha: .65),
            ]);
          }),
      );
    }
    if (inset && !contrast) {
      // Stroke inside the clip: the soft rim reads as an inner shadow with
      // one small blur, instead of a large even-odd path over the backdrop.
      final insetPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = shade.withValues(alpha: .34);
      if (!cheapShadow) {
        insetPaint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      }
      canvas.drawPath(path.shift(const Offset(1.5, 2)), insetPaint);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..color = shade.withValues(alpha: colors.dark ? .55 : .28),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = focused ? 3 : 1.5
        ..shader = focused || contrast
            ? null
            : ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
                light.withValues(
                  alpha: inset
                      ? .12
                      : glass
                      ? .90
                      : .20,
                ),
                light.withValues(
                  alpha: inset
                      ? .50
                      : glass
                      ? .28
                      : .08,
                ),
              ])
        ..color = focused
            ? colors.accent
            : contrast
            ? colors.muted
            : light,
    );
    if (blurCompensation > 0 && glass && !contrast) {
      _paintGlassCompensation(canvas, path, rect, light, blurCompensation);
    }
    canvas.restore();
  }

  /// Micro-noise + soft highlight that replaces the quality of a large
  /// Gaussian when the blur budget is BlurM/S/XS.
  void _paintGlassCompensation(
    Canvas canvas,
    Path path,
    Rect rect,
    Color light,
    double amount,
  ) {
    canvas.save();
    canvas.clipPath(path);
    // Soft top highlight (cheap vertical gradient — reads as frost catch).
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [light.withValues(alpha: .18 * amount), light.withValues(alpha: 0)],
          [0, .45],
        ),
    );
    // Sparse deterministic grain: fixed lattice, no RNG per frame.
    final grain = Paint()..color = light.withValues(alpha: .045 * amount);
    const step = 7.0;
    for (var y = rect.top + 3; y < rect.bottom; y += step) {
      var x = rect.left + ((y / step).truncate() % 2 == 0 ? 1.5 : 4.5);
      while (x < rect.right) {
        canvas.drawCircle(Offset(x, y), .6, grain);
        x += step;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LuminaMaterial old) =>
      old.shoulderWidth != shoulderWidth ||
      old.colors.dark != colors.dark ||
      old.colors.tint != colors.tint ||
      old.tint != tint ||
      old.radius != radius ||
      old.depth != depth ||
      old.shoulder != shoulder ||
      old.contrast != contrast ||
      old.focused != focused ||
      old.pressed != pressed ||
      old.glass != glass ||
      old.diffuseGlass != diffuseGlass ||
      old.cheapShadow != cheapShadow ||
      old.blurCompensation != blurCompensation;
}
