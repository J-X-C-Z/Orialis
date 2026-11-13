import 'dart:async';
import 'dart:math' as math;

import 'package:lumina_ui/lumina_ui.dart';

import '../../../core/database/app_database.dart';
import 'long_press_orderable.dart';
import 'task_quadrant.dart';

/// One continuous quadrant card with viewport-built rows and the shared reveal.
class TaskQuadrantSliver extends StatefulWidget {
  const TaskQuadrantSliver({
    required this.quadrant,
    required this.tasks,
    required this.itemBuilder,
    required this.onMove,
    this.onResetOrder,
    this.onAdd,
    this.onCompletionActivityChanged,
    super.key,
  });

  final TaskQuadrant quadrant;
  final List<Task> tasks;
  final IndexedWidgetBuilder itemBuilder;
  final ValueChanged<Task> onMove;

  /// Shown beside the count only while this quadrant has a manual order.
  final VoidCallback? onResetOrder;

  /// Creates a task already placed in this quadrant.
  final VoidCallback? onAdd;
  final ValueChanged<bool>? onCompletionActivityChanged;

  @override
  State<TaskQuadrantSliver> createState() => _TaskQuadrantSliverState();
}

class _TaskQuadrantSliverState extends State<TaskQuadrantSliver> {
  String get _storageId => 'quadrant:${widget.quadrant.name}';
  late bool _expanded = LuminaCardMemory.expanded(_storageId);
  // Several targets cover one card; count hovers so the cue spans the card.
  int _hovering = 0;

  void _hover(int delta) {
    if (!mounted) return;
    setState(() => _hovering = (_hovering + delta).clamp(0, 1 << 20));
  }

  Widget _target(Widget child) => DragTarget<OrderDrag<Task>>(
    onWillAcceptWithDetails: (details) {
      final accept = details.data.group != widget.quadrant;
      if (accept) _hover(1);
      return accept;
    },
    onLeave: (_) => _hover(-1),
    onAcceptWithDetails: (details) {
      _hover(-1);
      unawaited(LuminaHaptics.selection());
      widget.onMove(details.data.item);
    },
    builder: (context, candidates, rejected) => child,
  );

  @override
  Widget build(BuildContext context) {
    final itemBuilder = widget.itemBuilder;
    return LuminaPalette(
      palette: switch (widget.quadrant) {
        TaskQuadrant.urgentImportant => LuminaCardPalette.rose,
        TaskQuadrant.urgentOnly => LuminaCardPalette.amber,
        TaskQuadrant.importantOnly => LuminaCardPalette.ocean,
        TaskQuadrant.neither => LuminaCardPalette.sage,
        TaskQuadrant.unclassified => LuminaCardPalette.mist,
      },
      child: Builder(
        builder: (context) => LuminaCardHost(
          child: DecoratedSliver(
            decoration: LuminaCardDecoration.of(
              context,
              title: quadrantLabel(widget.quadrant),
              shoulder: true,
              shoulderTrailingSpace:
                  90 +
                  (widget.onResetOrder == null ? 0 : 40) +
                  (widget.onAdd == null ? 0 : 40),
            ),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: _target(
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: LuminaCardHeader(
                        title: quadrantLabel(widget.quadrant),
                        trailing: QuadrantHeaderTrailing(
                          count: widget.tasks.length,
                          dropping: _hovering > 0,
                          onResetOrder: widget.onResetOrder,
                          onAdd: widget.onAdd,
                        ),
                        expanded: _expanded,
                        onTitleTap: () {
                          setState(() => _expanded = !_expanded);
                          LuminaCardMemory.save(_storageId, _expanded);
                        },
                      ),
                    ),
                  ),
                ),
                LuminaSliverReveal(
                  visible: _expanded,
                  sliver: SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      16,
                      LuminaCardMetrics.titleToContent,
                      16,
                      0,
                    ),
                    sliver: LuminaCompletionList.sliver(
                      key: ValueKey(widget.quadrant),
                      itemKeys: [
                        for (final task in widget.tasks)
                          ValueKey('order:${widget.quadrant.name}:${task.id}'),
                      ],
                      itemBuilder: (context, index) =>
                          _target(itemBuilder(context, index)),
                      empty: _target(
                        Text(
                          '暂时没有事项',
                          style: LuminaTheme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      animateChanges: true,
                      onCompletionActivityChanged:
                          widget.onCompletionActivityChanged,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _target(
                    LuminaReveal(
                      visible: !_expanded,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                        child: Text(
                          quadrantCollapsedSummary(widget.tasks.length),
                          style: LuminaTheme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _target(const SizedBox(height: 16))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Item count at rest; while a task from another quadrant hovers, a clear
/// "drop here" cue replaces it so the target is obvious before release.
/// Shared by the phone sliver and the landscape/tablet quadrant cards.
class QuadrantCountBadge extends StatelessWidget {
  const QuadrantCountBadge({
    required this.count,
    required this.dropping,
    super.key,
  });
  final int count;
  final bool dropping;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return AnimatedSwitcher(
      duration: LuminaTheme.motionReducedOf(context)
          ? Duration.zero
          : LuminaMotion.fast,
      switchInCurve: luminaEaseOut,
      switchOutCurve: luminaEaseOut,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: .92, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: dropping
          ? Semantics(
              key: const ValueKey('drop'),
              liveRegion: true,
              child: Text(
                '松手移到这里',
                style: theme.textTheme.bodySmall.copyWith(
                  color: theme.colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : Text(
              count == 0 ? '' : '$count 项',
              key: const ValueKey('count'),
              style: theme.textTheme.bodySmall.copyWith(
                color: theme.colors.muted,
              ),
            ),
    );
  }
}

/// Count plus, when a quadrant has a manual order, the same small reset
/// button Today's sections use.
class QuadrantHeaderTrailing extends StatelessWidget {
  const QuadrantHeaderTrailing({
    required this.count,
    required this.dropping,
    this.onResetOrder,
    this.onAdd,
    super.key,
  });
  final int count;
  final bool dropping;
  final VoidCallback? onResetOrder, onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    // Card headers are top-aligned: a plain title is one text line tall while
    // the buttons keep a 44px tap target, so lift them onto the title's
    // centre line. A glass title chip is already button-high.
    final chip =
        LuminaGlassTitleScope.of(context) &&
        theme.data.neumorphic &&
        !MediaQuery.highContrastOf(context);
    final title = theme.textTheme.cardTitle;
    final line =
        MediaQuery.textScalerOf(context).scale(title.fontSize ?? 18) *
        (title.height ?? 1.3);
    final lift = chip || onResetOrder == null && onAdd == null
        ? 0.0
        : math.max(0.0, (44 - line) / 2);
    return Transform.translate(offset: Offset(0, -lift), child: _row());
  }

  Widget _row() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      QuadrantCountBadge(count: count, dropping: dropping),
      if (onResetOrder != null && !dropping)
        LuminaIconButton(
          tooltip: '恢复此象限默认排序',
          icon: const LuminaIcon(LuminaIcons.sortReset, size: 16),
          onPressed: onResetOrder,
        ),
      if (onAdd != null && !dropping)
        LuminaIconButton(
          tooltip: '在此象限新增事件',
          icon: const LuminaIcon(LuminaIcons.add, size: 16),
          onPressed: onAdd,
        ),
    ],
  );
}

/// Collapsed-card caption shared by phone and wide layouts.
String quadrantCollapsedSummary(int count) =>
    count == 0 ? '暂无事项' : '$count 项已收起，点标题展开';
