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
    final material = _LuminaMaterial(
      colors: theme.colors,
      tint: backing,
      radius: radius,
      depth: LuminaSurfaceDepth.recessed,
      shoulder: false,
      contrast: MediaQuery.highContrastOf(context),
      focused: focused,
      pressed: false,
      neumorphic: true,
      cheapShadow: theme.highPerformanceMode && opaque,
    );
    Widget well = CustomPaint(
      isComplex: true,
      painter: theme.highPerformanceMode && !opaque
          ? _LuminaBakedWell(material)
          : material,
      child: const SizedBox.expand(),
    );
    if (!opaque && !theme.highPerformanceMode) {
      // The opaque well hides the backdrop: filter only its own static paint.
      well = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
        child: well,
      );
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    well,
                    if (opaque)
                      ColoredBox(color: backing)
                    else
                      CustomPaint(
                        painter: _LuminaFrostFilm(
                          colors: theme.colors,
                          backing: backing,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
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
            cheapShadow: theme.highPerformanceMode,
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

/// A cached, paint-only frost film shared by both quality modes.
class _LuminaFrostFilm extends CustomPainter {
  const _LuminaFrostFilm({required this.colors, required this.backing});
  final LuminaColors colors;
  final Color backing;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final light = colors.tone(const Color(0xFFFFFFFF), const Color(0xFF71869C));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = _LuminaMaterial._cachedGradient(
          _LuminaMaterial._bodyGradientCache,
          ('frost-film', size, backing, light, colors.accent),
          () => ui.Gradient.linear(
            rect.topLeft,
            rect.bottomRight,
            [
              Color.lerp(backing, light, .20)!.withValues(alpha: .23),
              backing.withValues(alpha: .13),
              Color.lerp(backing, colors.accent, .10)!.withValues(alpha: .20),
            ],
            [0, .50, 1],
          ),
        ),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = _LuminaMaterial._grainShader
        ..color = Color.fromRGBO(255, 255, 255, colors.toneValue(.16, .10)),
    );
  }

  @override
  bool shouldRepaint(_LuminaFrostFilm old) =>
      old.backing != backing ||
      old.colors.darkProgress != colors.darkProgress ||
      old.colors.accent != colors.accent;
}

/// Cache the normal well including its local frost blur; text is never baked.
/// Fixed 2x resolution is sufficient for this soft layer, independent of DPR.
class _LuminaBakedWell extends CustomPainter {
  const _LuminaBakedWell(this.material);
  final _LuminaMaterial material;
  static final _cache = <Object, ui.Image>{};
  static int _bytes = 0;
  static const _byteLimit = 12 * 1024 * 1024;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final key = (
      size,
      material.radius,
      material.tint,
      material.colors.surface,
      material.colors.accent,
      material.colors.darkProgress,
      material.focused,
    );
    var image = _cache.remove(key);
    if (image == null) {
      final scale = math.min(2.0, 1024 / size.longestSide);
      final width = (size.width * scale).ceil();
      final height = (size.height * scale).ceil();
      final recorder = ui.PictureRecorder();
      final baked = Canvas(recorder)..scale(scale);
      final bounds = Offset.zero & size;
      baked.saveLayer(
        bounds.inflate(12),
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
      );
      material.paint(baked, size);
      baked.restore();
      final picture = recorder.endRecording();
      image = picture.toImageSync(width, height);
      picture.dispose();
      final bytes = width * height * 4;
      while (_cache.isNotEmpty &&
          (_cache.length >= 48 || _bytes + bytes > _byteLimit)) {
        final old = _cache.remove(_cache.keys.first)!;
        _bytes -= old.width * old.height * 4;
        old.dispose();
      }
      _bytes += bytes;
    }
    _cache[key] = image;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_LuminaBakedWell old) =>
      material.shouldRepaint(old.material);
}
