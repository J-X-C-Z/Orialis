import 'dart:math' as math;

import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

/// Native radar geometry uses the same zero and maximum for every series.
class ResponseChartRadar extends StatelessWidget {
  const ResponseChartRadar({
    required this.points,
    required this.maximum,
    required this.onInspect,
    super.key,
  });
  final List<Map<String, dynamic>> points;
  final double maximum;
  final ValueChanged<int> onInspect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = LuminaTheme.of(context);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          final center = Offset(
            constraints.maxWidth / 2,
            constraints.maxHeight / 2,
          );
          final delta = details.localPosition - center;
          final angle = math.atan2(delta.dy, delta.dx) + math.pi / 2;
          onInspect(
            (angle * points.length / (2 * math.pi)).round() % points.length,
          );
        },
        child: CustomPaint(
          painter: _RadarPainter(
            points: points,
            maximum: maximum,
            color: theme.colors.accent,
            grid: theme.colors.outline,
            textStyle: theme.textTheme.bodySmall.copyWith(
              color: theme.colors.ink,
            ),
            scaler: MediaQuery.textScalerOf(context),
          ),
          child: const SizedBox.expand(),
        ),
      );
    },
  );
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.points,
    required this.maximum,
    required this.color,
    required this.grid,
    required this.textStyle,
    required this.scaler,
  });
  final List<Map<String, dynamic>> points;
  final double maximum;
  final Color color, grid;
  final TextStyle textStyle;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.max(1.0, size.shortestSide / 2 - 36);
    Offset position(int index, double fraction) {
      final angle = index * 2 * math.pi / points.length - math.pi / 2;
      return center +
          Offset(math.cos(angle), math.sin(angle)) * radius * fraction;
    }

    Path polygon(double Function(int) fraction) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final p = position(i, fraction(i));
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path..close();
    }

    final gridPaint = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke;
    for (var ring = 1; ring <= 4; ring++) {
      canvas.drawPath(polygon((_) => ring / 4), gridPaint);
    }
    for (var i = 0; i < points.length; i++) {
      canvas.drawLine(center, position(i, 1), gridPaint);
      // Dense radars retain all axes in the readable legend and data list.
      if (i % (points.length / 12).ceil() != 0) continue;
      final text = TextPainter(
        text: TextSpan(text: '${i + 1}', style: textStyle),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      final p = position(i, 1 + 20 / radius);
      text.paint(canvas, p - Offset(text.width / 2, text.height / 2));
    }
    final path = polygon((i) => (points[i]['y'] as num).toDouble() / maximum);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: .18));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(
        position(i, (points[i]['y'] as num).toDouble() / maximum),
        4,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) =>
      points != oldDelegate.points ||
      maximum != oldDelegate.maximum ||
      color != oldDelegate.color ||
      grid != oldDelegate.grid ||
      textStyle != oldDelegate.textStyle ||
      scaler != oldDelegate.scaler;
}
