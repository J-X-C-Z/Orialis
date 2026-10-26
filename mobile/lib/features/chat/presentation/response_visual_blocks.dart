import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import 'response_chart_plot.dart';
import 'response_dashboard_blocks.dart';

class ResponseVisualBlock extends StatelessWidget {
  const ResponseVisualBlock({required this.data, super.key});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final items = (data['items'] as List).cast<Map<String, dynamic>>();
    return switch (data['type']) {
      'diagram' => _Diagram(data: data),
      'math' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final item in items) _Formula(item: item)],
      ),
      'plot' => ResponseChartPlot(data: data),
      'progress' => ResponseDashboardProgress(data: data),
      'heatmap' => ResponseDashboardHeatmap(data: data),
      'timeline' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            _TimelineEntry(item: items[i], index: i),
        ],
      ),
      'simulation' => _Simulation(item: items.single),
      _ => const SizedBox.shrink(),
    };
  }
}

class _Formula extends StatelessWidget {
  const _Formula({required this.item});
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(item['label'] as String),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Math.tex(
            item['source'] as String,
            textStyle: TextStyle(
              fontSize: 20,
              color: LuminaTheme.of(context).colors.ink,
            ),
            onErrorFallback: (_) =>
                LuminaSelectableText(item['source'] as String),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: LuminaButton(
            primary: false,
            onPressed: () => Clipboard.setData(
              ClipboardData(text: item['source'] as String),
            ),
            child: const Text('复制公式'),
          ),
        ),
      ],
    ),
  );
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.item, required this.index});
  final Map<String, dynamic> item;
  final int index;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 12),
          child: Text('${index + 1}.'),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item['label'] as String,
                style: LuminaTheme.of(context).textTheme.titleSmall,
              ),
              if (item['time'] != null) Text(item['time'] as String),
              if (item['detail'] != null)
                LuminaSelectableText(item['detail'] as String),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Diagram extends StatelessWidget {
  const _Diagram({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final items = (data['items'] as List).cast<Map<String, dynamic>>();
    final layout = data['layout'] ?? 'flow';
    const width = 720.0;
    final height = layout == 'graph'
        ? 600.0
        : math.max(240.0, items.length * 110.0);
    final positions = <String, Offset>{};
    if (layout == 'graph') {
      for (var i = 0; i < items.length; i++) {
        final angle = 2 * math.pi * i / items.length - math.pi / 2;
        positions[items[i]['id'] as String] = Offset(
          360 + 240 * math.cos(angle),
          300 + 220 * math.sin(angle),
        );
      }
    } else {
      final byId = {for (final item in items) item['id'] as String: item};
      for (var i = 0; i < items.length; i++) {
        var depth = 0;
        var parent = items[i]['parent'];
        while (parent != null) {
          depth++;
          parent = byId[parent]?['parent'];
        }
        positions[items[i]['id'] as String] = Offset(
          layout == 'mindmap'
              ? 100 + depth * (500 / math.max(1, items.length - 1))
              : 360,
          65 + i * 110.0,
        );
      }
    }
    final edges = <Map<String, dynamic>>[
      ...?((data['edges'] as List?)?.cast<Map<String, dynamic>>()),
      for (final item in items)
        if (item['parent'] != null) {'from': item['parent'], 'to': item['id']},
    ];
    if (edges.isEmpty && layout == 'flow') {
      for (var i = 1; i < items.length; i++) {
        edges.add({'from': items[i - 1]['id'], 'to': items[i]['id']});
      }
    }
    final theme = LuminaTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('双指缩放、拖动查看；点击节点展开说明'),
        const SizedBox(height: 8),
        SizedBox(
          height: 320,
          child: ClipRect(
            child: InteractiveViewer(
              maxScale: 8,
              child: SizedBox.expand(
                child: FittedBox(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _EdgesPainter(
                              positions: positions,
                              edges: edges,
                              color: theme.colors.accent,
                              textStyle: theme.textTheme.bodySmall.copyWith(
                                color: theme.colors.accent,
                              ),
                            ),
                          ),
                        ),
                        for (final item in items)
                          Positioned(
                            left: positions[item['id']]!.dx - 90,
                            top: positions[item['id']]!.dy - 32,
                            width: 180,
                            height: 64,
                            child: Semantics(
                              label: item['label'] as String,
                              button: true,
                              child: Material(
                                color: theme.colors.surface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: theme.colors.accent),
                                ),
                                child: InkWell(
                                  onTap: () => showDialog<void>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(item['label'] as String),
                                      content: SingleChildScrollView(
                                        child: LuminaSelectableText(
                                          (item['detail'] ?? item['label'])
                                              as String,
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: const Text('关闭'),
                                        ),
                                      ],
                                    ),
                                  ),
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Text(
                                        item['label'] as String,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
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
        // Native labels remain readable even when a large diagram is fitted down.
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final item in items)
              LuminaButton(
                primary: false,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(item['label'] as String),
                    content: LuminaSelectableText(
                      (item['detail'] ?? item['label']) as String,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
                child: Text(item['label'] as String),
              ),
          ],
        ),
      ],
    );
  }
}

class _EdgesPainter extends CustomPainter {
  _EdgesPainter({
    required this.positions,
    required this.edges,
    required this.color,
    required this.textStyle,
  });
  final Map<String, Offset> positions;
  final List<Map<String, dynamic>> edges;
  final Color color;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (final edge in edges) {
      final from = positions[edge['from']]!;
      final to = positions[edge['to']]!;
      if (from == to) continue;
      final direction = (to - from) / (to - from).distance;
      final start = from + direction * 38;
      final end = to - direction * 38;
      canvas.drawLine(start, end, paint);
      final side = Offset(-direction.dy, direction.dx);
      canvas.drawPath(
        Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(
            (end - direction * 10 + side * 5).dx,
            (end - direction * 10 + side * 5).dy,
          )
          ..lineTo(
            (end - direction * 10 - side * 5).dx,
            (end - direction * 10 - side * 5).dy,
          )
          ..close(),
        paint,
      );
      if (edge['label'] case final String label) {
        final text = TextPainter(
          text: TextSpan(text: label, style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 180);
        final middle = (start + end) / 2;
        text.paint(canvas, middle + const Offset(8, -18));
      }
    }
  }

  @override
  bool shouldRepaint(_EdgesPainter oldDelegate) =>
      positions != oldDelegate.positions ||
      edges != oldDelegate.edges ||
      color != oldDelegate.color ||
      textStyle != oldDelegate.textStyle;
}

/// Bounded, deterministic teaching functions; no generated code is evaluated.
List<FlSpot> responseSimulationPoints({
  required String kind,
  required int terms,
  required double amplitude,
  required double frequency,
}) => [
  for (var i = 0; i <= 120; i++)
    FlSpot(
      -math.pi + 2 * math.pi * i / 120,
      kind == 'sine'
          ? amplitude * math.sin(frequency * (-math.pi + 2 * math.pi * i / 120))
          : amplitude *
                4 /
                math.pi *
                List.generate(
                  terms,
                  (n) =>
                      math.sin(
                        (2 * n + 1) *
                            frequency *
                            (-math.pi + 2 * math.pi * i / 120),
                      ) /
                      (2 * n + 1),
                ).fold<double>(0, (sum, value) => sum + value),
    ),
];

class _Simulation extends StatefulWidget {
  const _Simulation({required this.item});
  final Map<String, dynamic> item;
  @override
  State<_Simulation> createState() => _SimulationState();
}

class _SimulationState extends State<_Simulation> {
  late int _terms;
  late double _amplitude;
  late double _frequency;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    _terms = (widget.item['terms'] as int?) ?? 5;
    _amplitude = (widget.item['amplitude'] as num?)?.toDouble() ?? 1;
    _frequency = (widget.item['frequency'] as num?)?.toDouble() ?? 1;
  }

  @override
  void didUpdateWidget(_Simulation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item != widget.item) _reset();
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.item['kind'] as String;
    final spots = responseSimulationPoints(
      kind: kind,
      terms: _terms,
      amplitude: _amplitude,
      frequency: _frequency,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.item['label'] as String),
        Text(
          kind == 'fourier' ? '方波傅里叶叠加：奇次谐波，项数 $_terms' : '正弦函数 y=A sin(ωx)',
        ),
        SizedBox(
          height: 220,
          child: LineChart(
            LineChartData(
              minX: -math.pi,
              maxX: math.pi,
              minY: -7,
              maxY: 7,
              titlesData: const FlTitlesData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  color: LuminaTheme.of(context).colors.accent,
                  dotData: const FlDotData(show: false),
                ),
              ],
            ),
            duration: Duration.zero,
          ),
        ),
        if (kind == 'fourier') ...[
          Text('项数：$_terms'),
          LuminaValueSlider(
            value: _terms.toDouble(),
            min: 1,
            max: 25,
            divisions: 24,
            onChanged: (value) => setState(() => _terms = value.round()),
          ),
        ],
        Text('振幅：${_amplitude.toStringAsFixed(1)}'),
        LuminaContinuousSlider(
          value: _amplitude,
          min: 0.1,
          max: 5,
          onChanged: (value) => setState(() => _amplitude = value),
        ),
        Text('频率：${_frequency.toStringAsFixed(1)}'),
        LuminaContinuousSlider(
          value: _frequency,
          min: 0.1,
          max: 5,
          onChanged: (value) => setState(() => _frequency = value),
        ),
        LuminaButton(
          primary: false,
          onPressed: () => setState(_reset),
          child: const Text('恢复参数'),
        ),
      ],
    );
  }
}
