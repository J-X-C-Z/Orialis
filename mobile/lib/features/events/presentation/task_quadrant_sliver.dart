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
    this.onCompletionActivityChanged,
    super.key,
  });

  final TaskQuadrant quadrant;
  final List<Task> tasks;
  final IndexedWidgetBuilder itemBuilder;
  final ValueChanged<Task> onMove;
  final ValueChanged<bool>? onCompletionActivityChanged;

  @override
  State<TaskQuadrantSliver> createState() => _TaskQuadrantSliverState();
}

class _TaskQuadrantSliverState extends State<TaskQuadrantSliver> {
  String get _storageId => 'quadrant:${widget.quadrant.name}';
  late bool _expanded = LuminaCardMemory.expanded(_storageId);

  Widget _target(Widget child) => DragTarget<OrderDrag<Task>>(
    onWillAcceptWithDetails: (details) => details.data.group != widget.quadrant,
    onAcceptWithDetails: (details) => widget.onMove(details.data.item),
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
              shoulderTrailingSpace: 26,
            ),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: _target(
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: LuminaCardHeader(
                        title: quadrantLabel(widget.quadrant),
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
                          widget.tasks.isEmpty ? '暂无事项' : '事项已收起',
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
