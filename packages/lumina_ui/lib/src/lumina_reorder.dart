part of 'design_components.dart';

/// Carries an item and the list it came from while a row is being dragged.
class LuminaOrderDrag<T> {
  const LuminaOrderDrag({required this.item, required this.group});

  final T item;
  final Object group;
}

/// A Lumina-friendly row that can be reordered by long pressing and dragging.
/// Different groups may opt into accepting the drag as a cross-list move.
class LuminaLongPressOrderable<T> extends StatelessWidget {
  const LuminaLongPressOrderable({
    required this.item,
    required this.group,
    required this.child,
    required this.feedback,
    required this.onReorder,
    this.onMoveAcrossGroup,
    super.key,
  });

  final T item;
  final Object group;
  final Widget child;
  final Widget feedback;
  final void Function(T dragged, T target) onReorder;
  final void Function(T dragged, T target)? onMoveAcrossGroup;

  @override
  Widget build(BuildContext context) => DragTarget<LuminaOrderDrag<T>>(
    onWillAcceptWithDetails: (details) =>
        details.data.item != item &&
        (details.data.group == group || onMoveAcrossGroup != null),
    onAcceptWithDetails: (details) {
      if (details.data.group == group) {
        onReorder(details.data.item, item);
      } else {
        onMoveAcrossGroup?.call(details.data.item, item);
      }
    },
    builder: (context, candidates, rejected) => AnimatedScale(
      scale: candidates.isEmpty ? 1 : 1.025,
      duration: LuminaTheme.motionReducedOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 130),
      child: LongPressDraggable<LuminaOrderDrag<T>>(
        data: LuminaOrderDrag(item: item, group: group),
        onDragUpdate: (details) {
          final scrollable = Scrollable.maybeOf(context);
          final box = scrollable?.context.findRenderObject();
          if (scrollable == null || box is! RenderBox) return;
          final y = box.globalToLocal(details.globalPosition).dy;
          final delta = y < 56
              ? -16.0
              : y > box.size.height - 56
              ? 16.0
              : 0.0;
          if (delta != 0) {
            final position = scrollable.position;
            position.jumpTo(
              (position.pixels + delta).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              ),
            );
          }
        },
        feedback: Opacity(opacity: .92, child: feedback),
        childWhenDragging: Opacity(opacity: .28, child: child),
        child: child,
      ),
    ),
  );
}
