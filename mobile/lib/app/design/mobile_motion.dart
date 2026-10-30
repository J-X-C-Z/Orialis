import 'package:lumina_ui/lumina_ui.dart';

/// One scroll policy for every mobile route, including short lists.
class OrialisMobileMotionScope extends StatelessWidget {
  const OrialisMobileMotionScope({
    required this.child,
    this.enabled = true,
    super.key,
  });
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        overscroll: false,
        physics: LuminaTheme.motionReducedOf(context)
            ? const ClampingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              )
            : const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
      ),
      child: child,
    );
  }
}

/// Keeps one live subtree so editors, focus and scroll positions survive changes.
class OrialisContentTransition extends StatefulWidget {
  const OrialisContentTransition({
    required this.changeKey,
    required this.child,
    this.direction = 0,
    super.key,
  });
  final Object changeKey;
  final Widget child;
  final double direction;

  @override
  State<OrialisContentTransition> createState() =>
      _OrialisContentTransitionState();
}

class _OrialisContentTransitionState extends State<OrialisContentTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: LuminaMotion.fast,
    value: 1,
  );
  late final _progress = _controller.drive(CurveTween(curve: luminaEaseOut));
  Animation<Offset> _position = const AlwaysStoppedAnimation(Offset.zero);
  Animation<double> _opacity = const AlwaysStoppedAnimation(1);

  @override
  void didUpdateWidget(OrialisContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changeKey == widget.changeKey) return;
    final reduced = LuminaTheme.motionReducedOf(context);
    final start = _controller.isAnimating
        ? _position.value
        : Offset(widget.direction * .025, 0);
    final opacity = _controller.isAnimating ? _opacity.value : .92;
    _position = reduced
        ? const AlwaysStoppedAnimation(Offset.zero)
        : Tween<Offset>(begin: start, end: Offset.zero).animate(_progress);
    _opacity = Tween<double>(begin: opacity, end: 1).animate(_progress);
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: SlideTransition(
      position: LuminaTheme.motionReducedOf(context)
          ? const AlwaysStoppedAnimation(Offset.zero)
          : _position,
      child: widget.child,
    ),
  );
}
