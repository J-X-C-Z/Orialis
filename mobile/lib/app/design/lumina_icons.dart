part of 'design_components.dart';

enum LuminaIcons {
  today,
  tasks,
  chat,
  calendar,
  person,
  add,
  close,
  back,
  chevronRight,
  more,
  check,
  search,
  send,
  attachment,
  folder,
  clock,
  settings,
  sync,
  error,
  logout,
  server,
  moon,
  sun,
  arrowLeft,
  arrowRight,
  home,
  image,
  camera,
  file,
  terminal,
  sparkles,
  notification,
  play,
  shield,
  devices,
  cloud,
  info,
  warning,
  voice,
  chevronDown,
  checkCircle,
  branch,
}

class LuminaIcon extends StatelessWidget {
  const LuminaIcon(this.icon, {this.size = 22, this.color, super.key});
  final LuminaIcons icon;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _IconPainter(icon, color ?? LuminaTheme.of(context).colors.ink),
    ),
  );
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.icon, this.color);
  final LuminaIcons icon;
  final Color color;
  @override
  void paint(Canvas c, Size s) {
    c.scale(s.width / 24, s.height / 24);
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    void line(double a, double b, double d, double e) =>
        c.drawLine(Offset(a, b), Offset(d, e), p);
    void path(List<Offset> points, {bool closed = false}) {
      final q = Path()..addPolygon(points, closed);
      c.drawPath(q, p);
    }

    void box(double l, double t, double r, double b) => c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(l, t, r, b),
        const Radius.circular(3),
      ),
      p,
    );
    switch (icon) {
      case LuminaIcons.add:
        line(12, 5, 12, 19);
        line(5, 12, 19, 12);
        break;
      case LuminaIcons.close:
        line(6, 6, 18, 18);
        line(18, 6, 6, 18);
        break;
      case LuminaIcons.check:
      case LuminaIcons.checkCircle:
        if (icon == LuminaIcons.checkCircle) {
          c.drawCircle(const Offset(12, 12), 9, p);
        }
        path([const Offset(6, 12), const Offset(10, 16), const Offset(18, 8)]);
        break;
      case LuminaIcons.back:
      case LuminaIcons.arrowLeft:
        path([const Offset(10, 5), const Offset(3, 12), const Offset(10, 19)]);
        line(3, 12, 21, 12);
        break;
      case LuminaIcons.arrowRight:
        line(3, 12, 21, 12);
        path([const Offset(14, 5), const Offset(21, 12), const Offset(14, 19)]);
        break;
      case LuminaIcons.chevronRight:
        path([const Offset(9, 5), const Offset(16, 12), const Offset(9, 19)]);
        break;
      case LuminaIcons.chevronDown:
        path([const Offset(5, 9), const Offset(12, 16), const Offset(19, 9)]);
        break;
      case LuminaIcons.more:
        for (final x in [5.0, 12.0, 19.0]) {
          c.drawCircle(Offset(x, 12), 1, p);
        }
        break;
      case LuminaIcons.calendar:
      case LuminaIcons.today:
        box(3, 5, 21, 21);
        line(3, 10, 21, 10);
        line(8, 3, 8, 7);
        line(16, 3, 16, 7);
        if (icon == LuminaIcons.today) c.drawCircle(const Offset(12, 15), 2, p);
        break;
      case LuminaIcons.tasks:
        for (final y in [6.0, 12.0, 18.0]) {
          line(10, y, 21, y);
          path([Offset(3, y), Offset(5, y + 2), Offset(8, y - 2)]);
        }
        break;
      case LuminaIcons.chat:
        path([
          const Offset(4, 3),
          const Offset(20, 3),
          const Offset(21, 17),
          const Offset(9, 17),
          const Offset(4, 21),
        ], closed: true);
        line(8, 8, 16, 8);
        line(8, 12, 14, 12);
        break;
      case LuminaIcons.person:
        c.drawCircle(const Offset(12, 7), 4, p);
        c.drawArc(const Rect.fromLTWH(4, 13, 16, 15), 3.14, 3.14, false, p);
        break;
      case LuminaIcons.search:
        c.drawCircle(const Offset(10, 10), 6, p);
        line(15, 15, 21, 21);
        break;
      case LuminaIcons.send:
        line(12, 20, 12, 4);
        path([const Offset(5, 11), const Offset(12, 4), const Offset(19, 11)]);
        break;
      case LuminaIcons.clock:
        c.drawCircle(const Offset(12, 12), 9, p);
        path([const Offset(12, 6), const Offset(12, 12), const Offset(16, 14)]);
        break;
      case LuminaIcons.folder:
        path([
          const Offset(3, 6),
          const Offset(9, 6),
          const Offset(11, 9),
          const Offset(21, 9),
          const Offset(21, 20),
          const Offset(3, 20),
        ], closed: true);
        break;
      case LuminaIcons.image:
      case LuminaIcons.camera:
        box(3, 5, 21, 20);
        if (icon == LuminaIcons.camera) {
          c.drawCircle(const Offset(12, 12), 4, p);
          line(8, 3, 15, 3);
        } else {
          c.drawCircle(const Offset(8, 10), 1.5, p);
          path([
            const Offset(4, 19),
            const Offset(11, 12),
            const Offset(16, 17),
            const Offset(20, 13),
          ]);
        }
        break;
      case LuminaIcons.file:
        box(5, 3, 19, 21);
        line(8, 10, 16, 10);
        line(8, 14, 16, 14);
        line(8, 17, 13, 17);
        break;
      case LuminaIcons.home:
        path([
          const Offset(2, 10),
          const Offset(12, 2),
          const Offset(22, 10),
          const Offset(20, 10),
          const Offset(20, 21),
          const Offset(4, 21),
          const Offset(4, 10),
        ], closed: true);
        break;
      case LuminaIcons.terminal:
        box(2, 4, 22, 20);
        path([const Offset(6, 9), const Offset(9, 12), const Offset(6, 15)]);
        line(12, 15, 17, 15);
        break;
      case LuminaIcons.play:
        path([
          const Offset(7, 4),
          const Offset(20, 12),
          const Offset(7, 20),
        ], closed: true);
        break;
      case LuminaIcons.info:
      case LuminaIcons.error:
        c.drawCircle(const Offset(12, 12), 9, p);
        line(12, 10, 12, 16);
        c.drawCircle(const Offset(12, 6), .5, p);
        break;
      case LuminaIcons.warning:
        path([
          const Offset(12, 3),
          const Offset(22, 21),
          const Offset(2, 21),
        ], closed: true);
        line(12, 9, 12, 14);
        line(12, 17, 12, 18);
        break;
      case LuminaIcons.moon:
        c.drawPath(
          Path()
            ..moveTo(19, 17)
            ..cubicTo(6, 21, 2, 7, 12, 3)
            ..cubicTo(9, 12, 14, 15, 19, 17),
          p,
        );
        break;
      case LuminaIcons.sun:
        c.drawCircle(const Offset(12, 12), 4, p);
        for (final v in [
          const Offset(0, 8),
          const Offset(8, 0),
          const Offset(0, -8),
          const Offset(-8, 0),
        ]) {
          c.drawLine(
            const Offset(12, 12) + v * .8,
            const Offset(12, 12) + v,
            p,
          );
        }
        break;
      case LuminaIcons.shield:
        path([
          const Offset(12, 2),
          const Offset(21, 6),
          const Offset(19, 16),
          const Offset(12, 22),
          const Offset(5, 16),
          const Offset(3, 6),
        ], closed: true);
        break;
      case LuminaIcons.server:
      case LuminaIcons.devices:
        box(3, 4, 21, 20);
        line(3, 12, 21, 12);
        line(7, 8, 8, 8);
        line(7, 16, 8, 16);
        break;
      case LuminaIcons.settings:
        c.drawCircle(const Offset(12, 12), 8, p);
        c.drawCircle(const Offset(12, 12), 3, p);
        for (final x in [2.0, 22.0]) {
          line(x, 10, x, 14);
        }
        break;
      case LuminaIcons.sync:
        c.drawArc(const Rect.fromLTWH(4, 4, 16, 16), .3, 4.8, false, p);
        path([const Offset(16, 2), const Offset(20, 5), const Offset(16, 8)]);
        break;
      case LuminaIcons.logout:
        box(3, 3, 13, 21);
        line(10, 12, 22, 12);
        path([const Offset(18, 8), const Offset(22, 12), const Offset(18, 16)]);
        break;
      case LuminaIcons.attachment:
        c.drawPath(
          Path()
            ..moveTo(8, 13)
            ..lineTo(15, 6)
            ..cubicTo(20, 2, 24, 7, 20, 11)
            ..lineTo(10, 21)
            ..cubicTo(3, 25, 0, 17, 5, 12)
            ..lineTo(14, 3),
          p,
        );
        break;
      case LuminaIcons.notification:
        path([
          const Offset(4, 17),
          const Offset(6, 14),
          const Offset(6, 8),
          const Offset(9, 4),
          const Offset(15, 4),
          const Offset(18, 8),
          const Offset(18, 14),
          const Offset(20, 17),
        ], closed: true);
        line(10, 21, 14, 21);
        break;
      case LuminaIcons.voice:
        box(9, 3, 15, 15);
        c.drawArc(const Rect.fromLTWH(5, 7, 14, 13), 0, 3.14, false, p);
        line(12, 20, 12, 23);
        break;
      case LuminaIcons.cloud:
        c.drawPath(
          Path()
            ..moveTo(5, 19)
            ..cubicTo(-1, 16, 2, 9, 7, 10)
            ..cubicTo(9, 0, 20, 3, 20, 11)
            ..cubicTo(26, 13, 23, 19, 19, 19)
            ..close(),
          p,
        );
        break;
      case LuminaIcons.branch:
        line(6, 4, 6, 20);
        line(6, 12, 18, 12);
        line(18, 12, 18, 4);
        c.drawCircle(const Offset(6, 4), 2, p);
        c.drawCircle(const Offset(18, 4), 2, p);
        break;
      case LuminaIcons.sparkles:
        path([
          const Offset(12, 2),
          const Offset(15, 9),
          const Offset(22, 12),
          const Offset(15, 15),
          const Offset(12, 22),
          const Offset(9, 15),
          const Offset(2, 12),
          const Offset(9, 9),
        ], closed: true);
        break;
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.icon != icon || old.color != color;
}
