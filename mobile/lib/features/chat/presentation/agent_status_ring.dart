import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

enum AgentRingStatus { unknown, online, offline, answering, waiting, error }

class AgentStatusRing extends StatefulWidget {
  const AgentStatusRing({
    required this.status,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final AgentRingStatus status;
  final String label;
  final VoidCallback onPressed;

  @override
  State<AgentStatusRing> createState() => _AgentStatusRingState();
}

class _AgentStatusRingState extends State<AgentStatusRing>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _phase = AnimationController(vsync: this);
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(AgentStatusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _updateAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateAnimation();
  }

  void _updateAnimation() {
    final active =
        widget.status == AgentRingStatus.answering ||
        widget.status == AgentRingStatus.waiting;
    if (!active ||
        !_foreground ||
        !TickerMode.valuesOf(context).enabled ||
        LuminaTheme.motionReducedOf(context)) {
      _phase.stop();
      _phase.value = 0;
      return;
    }
    // Match LuminaProgress's rotation; waiting breathes over eight UI beats.
    final duration = widget.status == AgentRingStatus.answering
        ? const Duration(milliseconds: 1300)
        : LuminaMotion.standard * 8;
    if (!_phase.isAnimating || _phase.duration != duration) {
      _phase.duration = duration;
      _phase.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    final color = switch (widget.status) {
      AgentRingStatus.error => colors.danger,
      AgentRingStatus.unknown || AgentRingStatus.offline => colors.muted,
      _ => colors.accent,
    };
    return Tooltip(
      message: widget.label,
      excludeFromSemantics: true,
      child: LuminaIconButton(
        onPressed: widget.onPressed,
        tooltip: widget.label,
        icon: RepaintBoundary(
          child: AnimatedSwitcher(
            duration: LuminaTheme.motionReducedOf(context)
                ? Duration.zero
                : LuminaMotion.fast,
            switchInCurve: luminaEaseOut,
            switchOutCurve: luminaEaseOut,
            child: CustomPaint(
              key: ValueKey(widget.status),
              size: const Size.square(28),
              painter: _RingPainter(widget.status, color, _phase),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.status, this.color, this.phase) : super(repaint: phase);

  final AgentRingStatus status;
  final Color color;
  final Animation<double> phase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: 11);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;
    void arc(double start, double sweep) =>
        canvas.drawArc(rect, start, sweep, false, stroke);
    void dot(double radius) => canvas.drawCircle(center, radius, fill);
    switch (status) {
      case AgentRingStatus.online:
        canvas.drawOval(rect, stroke);
        dot(3);
      case AgentRingStatus.offline:
        for (var i = 0; i < 6; i++) {
          arc(i * math.pi / 3, math.pi / 5);
        }
        canvas.drawLine(
          center + const Offset(-4, 4),
          center + const Offset(4, -4),
          stroke,
        );
      case AgentRingStatus.answering:
        canvas.drawOval(rect, stroke..color = color.withValues(alpha: .22));
        stroke.color = color;
        arc(-math.pi / 2 + phase.value * math.pi * 2, math.pi * .7);
        for (var i = -1; i <= 1; i++) {
          canvas.drawCircle(center + Offset(i * 4, 0), 1.2, fill);
        }
      case AgentRingStatus.waiting:
        for (var i = 0; i < 4; i++) {
          arc(-math.pi / 2 + i * math.pi / 2, math.pi / 3);
        }
        final breath = (1 - math.cos(phase.value * math.pi * 2)) / 2;
        dot(2.3 + breath * .8);
      case AgentRingStatus.error:
        arc(-math.pi / 2 + .3, math.pi - .6);
        arc(math.pi / 2 + .3, math.pi - .6);
        canvas.drawLine(center + const Offset(0, -4), center, stroke);
        canvas.drawCircle(center + const Offset(0, 4), 1.2, fill);
      case AgentRingStatus.unknown:
        canvas.drawOval(rect, stroke..color = color.withValues(alpha: .5));
        stroke.color = color;
        final question = Path()
          ..moveTo(center.dx - 2.8, center.dy - 3)
          ..cubicTo(
            center.dx - 2.8,
            center.dy - 7,
            center.dx + 4,
            center.dy - 7,
            center.dx + 2.4,
            center.dy - 2,
          )
          ..lineTo(center.dx, center.dy)
          ..lineTo(center.dx, center.dy + 1);
        canvas.drawPath(question, stroke);
        canvas.drawCircle(center + const Offset(0, 5), 1, fill);
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      status != oldDelegate.status ||
      color != oldDelegate.color ||
      phase != oldDelegate.phase;
}
