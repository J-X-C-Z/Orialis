import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

/// These indicators display supplied measurements only; they never advance.
class ResponseDashboardProgress extends StatelessWidget {
  const ResponseDashboardProgress({required this.data, super.key});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final ring = data['style'] == 'ring';
    final unit = data['unit'] ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in data['items'] as List)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Builder(
              builder: (context) {
                final max = item['max'] ?? 100;
                final ratio =
                    (item['value'] as num).toDouble() / (max as num).toDouble();
                final progress = ratio.clamp(0.0, 1.0);
                final percentage = '${(ratio * 100).toStringAsFixed(1)}%';
                return Semantics(
                  label:
                      '${item['label']}，${item['value']} / $max$unit，$percentage',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        item['label'] as String,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Text('${item['value']} / $max$unit · $percentage'),
                      const SizedBox(height: 10),
                      if (ring)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: SizedBox.square(
                            dimension: 72,
                            child: CircularProgressIndicator(
                              value: progress,
                              color: theme.colors.accent,
                              backgroundColor: theme.colors.recessedSurface,
                              strokeWidth: 8,
                            ),
                          ),
                        )
                      else
                        LuminaSurface(
                          depth: LuminaSurfaceDepth.recessed,
                          radius: 8,
                          padding: const EdgeInsets.all(2),
                          child: SizedBox(
                            height: 10,
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(end: progress),
                              duration:
                                  LuminaTheme.motionReducedOf(context) ||
                                      theme.highPerformanceMode
                                  ? Duration.zero
                                  : const Duration(milliseconds: 180),
                              curve: luminaEaseOut,
                              builder: (context, value, _) => Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: FractionallySizedBox(
                                  widthFactor: value.clamp(0.0, 1.0),
                                  heightFactor: 1,
                                  child: DecoratedBox(
                                    key: ValueKey(
                                      'response-progress-fill-${item['label']}',
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Color.lerp(
                                            theme.colors.accent,
                                            theme.colors.surface,
                                            .28,
                                          )!,
                                          theme.colors.accent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (item['detail'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: LuminaSelectableText(item['detail'] as String),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class ResponseDashboardHeatmap extends StatefulWidget {
  const ResponseDashboardHeatmap({required this.data, super.key});
  final Map<String, dynamic> data;

  @override
  State<ResponseDashboardHeatmap> createState() =>
      _ResponseDashboardHeatmapState();
}

class _ResponseDashboardHeatmapState extends State<ResponseDashboardHeatmap> {
  Map<String, dynamic>? _selectedItem;

  @override
  void didUpdateWidget(ResponseDashboardHeatmap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _selectedItem = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    final items = [
      ...(widget.data['items'] as List).cast<Map<String, dynamic>>(),
    ]..sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    final maximum = items
        .map((item) => (item['value'] as num).toDouble())
        .reduce(math.max);
    final unit = widget.data['unit'] ?? '';
    final selected = _selectedItem;
    Color shade(double fraction) => Color.lerp(
      theme.colors.recessedSurface,
      theme.colors.accent,
      .08 + .30 * fraction,
    )!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('活动热力图', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        const Text('点击日期查看记录'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final minWidth = MediaQuery.textScalerOf(context)
                .scale(64)
                .clamp(80.0, 160.0);
            final columns = math.max(
              1,
              ((constraints.maxWidth + 8) / (minWidth + 8)).floor(),
            );
            final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (index, item) in items.indexed)
                  SizedBox(
                    width: width,
                    child: Semantics(
                      button: true,
                      selected: identical(_selectedItem, item),
                      label:
                          '${item['date']}，${item['label']}，${item['value']}$unit',
                      child: Material(
                        color: shade(
                          maximum == 0
                              ? 0
                              : (item['value'] as num).toDouble() / maximum,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: identical(_selectedItem, item)
                                ? theme.colors.accent
                                : theme.colors.outline,
                            width: identical(_selectedItem, item) ? 2 : 1,
                          ),
                        ),
                        child: InkWell(
                          key: ValueKey('heatmap-${item['date']}-$index'),
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(() => _selectedItem = item),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 72),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    (item['date'] as String).substring(5),
                                    style: theme.textTheme.bodySmall.copyWith(
                                      color: theme.colors.ink,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${item['value']}$unit',
                                    style: theme.textTheme.titleSmall.copyWith(
                                      color: theme.colors.ink,
                                    ),
                                  ),
                                ],
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
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('少 · 0$unit'),
            for (var i = 0; i < 5; i++)
              ExcludeSemantics(
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: shade(i / 4),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            Text('多 · $maximum$unit'),
          ],
        ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    selected['date'] as String,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(selected['label'] as String),
                  LuminaSelectableText('数值：${selected['value']}$unit'),
                ],
              ),
            ),
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('查看数据'),
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    '${item['date']} · ${item['label']}：${item['value']}$unit',
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
