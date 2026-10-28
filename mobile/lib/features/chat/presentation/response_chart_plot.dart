import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import 'response_chart_radar.dart';

class ResponseChartPlot extends StatefulWidget {
  const ResponseChartPlot({required this.data, super.key});
  final Map<String, dynamic> data;

  @override
  State<ResponseChartPlot> createState() => _ResponseChartPlotState();
}

class _ResponseChartPlotState extends State<ResponseChartPlot> {
  int _selected = 0;
  String? _inspection;

  @override
  void didUpdateWidget(ResponseChartPlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _selected = 0;
      _inspection = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = (widget.data['items'] as List).cast<Map<String, dynamic>>();
    final kind = widget.data['kind'] as String;
    final item = items[_selected];
    final points = (item['points'] as List).cast<Map<String, dynamic>>();
    final theme = LuminaTheme.of(context);
    final color = theme.colors.accent;
    final unit = widget.data['unit'] ?? '';
    final xUnit = widget.data['xUnit'] ?? '';
    final xLabel = widget.data['xLabel'] ?? 'x';
    final yLabel = widget.data['yLabel'] ?? 'y';
    final spots = [
      for (final p in points)
        FlSpot((p['x'] as num).toDouble(), (p['y'] as num).toDouble()),
    ];
    final minX = spots.map((p) => p.x).reduce(math.min);
    final maxX = spots.map((p) => p.x).reduce(math.max);
    // A fixed domain across series keeps switching from distorting comparisons.
    final allY = [
      for (final series in items)
        for (final p in series['points'] as List) (p['y'] as num).toDouble(),
    ];
    final zeroBaseline = const {'bar', 'area', 'radar'}.contains(kind);
    final low = allY.reduce(math.min);
    final high = allY.reduce(math.max);
    final minY = zeroBaseline ? math.min(0.0, low) : low;
    final maxY = zeroBaseline ? math.max(0.0, high) : high;
    final lowerY = minY == maxY ? minY - (zeroBaseline ? 0 : 1) : minY;
    final upperY = minY == maxY ? maxY + 1 : maxY;
    final grid = FlGridData(
      show: true,
      drawVerticalLine: false,
      getDrawingHorizontalLine: (_) =>
          FlLine(color: theme.colors.outline, strokeWidth: 1),
    );
    final border = FlBorderData(
      show: true,
      border: Border.all(color: theme.colors.outline),
    );
    // Only two ticks per axis: full-size text also fits a 240px card at 2x.
    final axisStyle = theme.textTheme.bodySmall.copyWith(
      color: theme.colors.ink,
    );
    final axisHeight =
        MediaQuery.textScalerOf(context).scale(axisStyle.fontSize ?? 12) * 2 +
        8;
    Widget tick(String text) => Padding(
      padding: const EdgeInsets.all(4),
      child: Text(text, style: axisStyle, textAlign: TextAlign.center),
    );
    final titles = FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      leftTitles: const AxisTitles(),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: axisHeight,
          interval: kind == 'bar'
              ? math.max(1.0, points.length - 1.0)
              : math.max(1e-6, maxX - minX),
          getTitlesWidget: (value, _) {
            if (kind == 'bar') {
              final index = value.round();
              return index == 0 || index == points.length - 1
                  ? tick(
                      '${points[index]['label'] ?? _compact((points[index]['x'] as num).toDouble())}',
                    )
                  : const SizedBox.shrink();
            }
            return (value - minX).abs() < 1e-7 || (value - maxX).abs() < 1e-7
                ? tick(_compact(value))
                : const SizedBox.shrink();
          },
        ),
      ),
    );
    String pointText(int index) {
      final p = points[index];
      final label = p['label'];
      return '${label == null ? '' : '$label · '}$xLabel=${p['x']}$xUnit, $yLabel=${p['y']}$unit';
    }

    void inspect(int index) {
      if (index >= 0 && index < points.length) {
        setState(() => _inspection = '${item['label']}: ${pointText(index)}');
      }
    }

    double total(Map<String, dynamic> series) => (series['points'] as List)
        .fold<double>(0, (sum, p) => sum + (p['y'] as num).toDouble());
    Color seriesColor(int index) =>
        HSVColor.fromColor(color)
            .withHue((HSVColor.fromColor(color).hue + index * 47) % 360)
            .toColor();
    final Widget chart;
    if (kind == 'pie') {
      chart = PieChart(
        PieChartData(
          centerSpaceRadius: 24,
          sectionsSpace: 3,
          sections: [
            for (var i = 0; i < items.length; i++)
              PieChartSectionData(
                value: total(items[i]),
                title: '${i + 1}',
                titleStyle: TextStyle(
                  color:
                      ThemeData.estimateBrightnessForColor(seriesColor(i)) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                ),
                color: seriesColor(i),
                radius: i == _selected ? 58 : 48,
              ),
          ],
          pieTouchData: PieTouchData(
            touchCallback: (event, response) {
              final index = response?.touchedSection?.touchedSectionIndex;
              if (event.isInterestedForInteractions &&
                  index != null &&
                  index >= 0 &&
                  index < items.length) {
                setState(() {
                  _selected = index;
                  _inspection = null;
                });
              }
            },
          ),
        ),
        duration: Duration.zero,
      );
    } else if (kind == 'radar') {
      chart = ResponseChartRadar(
        points: points,
        maximum: math.max(1, high),
        onInspect: inspect,
      );
    } else if (kind == 'bar') {
      final dark = theme.brightness == Brightness.dark;
      chart = BarChart(
        BarChartData(
          minY: lowerY,
          maxY: upperY,
          titlesData: titles,
          gridData: grid,
          borderData: FlBorderData(show: false),
          barGroups: [
            for (var i = 0; i < points.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: spots[i].y,
                    fromY: 0,
                    width: math.max(2, math.min(20, 180 / points.length)),
                    gradient: LinearGradient(
                      colors: [
                        Color.lerp(color, Colors.white, dark ? .18 : .28)!,
                        color,
                        Color.lerp(color, Colors.black, dark ? .20 : .12)!,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(3),
                    borderSide: BorderSide(
                      color: theme.colors.ink.withValues(
                        alpha: dark ? .24 : .16,
                      ),
                      width: .7,
                    ),
                  ),
                ],
              ),
          ],
          barTouchData: BarTouchData(
            handleBuiltInTouches: false,
            touchCallback: (event, response) {
              final index = response?.spot?.touchedBarGroupIndex;
              if (event.isInterestedForInteractions && index != null) {
                inspect(index);
              }
            },
          ),
        ),
        duration: Duration.zero,
      );
    } else if (kind == 'scatter') {
      chart = ScatterChart(
        ScatterChartData(
          minX: minX == maxX ? minX - 1 : minX,
          maxX: minX == maxX ? maxX + 1 : maxX,
          minY: lowerY,
          maxY: upperY,
          titlesData: titles,
          gridData: grid,
          borderData: border,
          scatterSpots: [
            for (final p in spots)
              ScatterSpot(
                p.x,
                p.y,
                dotPainter: FlDotCirclePainter(radius: 4, color: color),
              ),
          ],
          scatterTouchData: ScatterTouchData(
            handleBuiltInTouches: false,
            touchCallback: (event, response) {
              final index = response?.touchedSpot?.spotIndex;
              if (event.isInterestedForInteractions && index != null) {
                inspect(index);
              }
            },
          ),
        ),
        duration: Duration.zero,
      );
    } else {
      chart = LineChart(
        LineChartData(
          minX: minX == maxX ? minX - 1 : minX,
          maxX: minX == maxX ? maxX + 1 : maxX,
          minY: lowerY,
          maxY: upperY,
          titlesData: titles,
          gridData: grid,
          borderData: border,
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              color: color,
              isCurved: false,
              barWidth: 2,
              dotData: FlDotData(show: points.length <= 12),
              belowBarData: BarAreaData(
                show: kind == 'area',
                color: color.withValues(alpha: .18),
                applyCutOffY: true,
                cutOffY: 0,
              ),
              aboveBarData: BarAreaData(
                show: kind == 'area' && minY < 0,
                color: color.withValues(alpha: .18),
                applyCutOffY: true,
                cutOffY: 0,
              ),
            ),
          ],
          lineTouchData: LineTouchData(
            handleBuiltInTouches: false,
            touchCallback: (event, response) {
              final touched = response?.lineBarSpots;
              if (event.isInterestedForInteractions &&
                  touched != null &&
                  touched.isNotEmpty) {
                inspect(touched.first.spotIndex);
              }
            },
          ),
        ),
        duration: Duration.zero,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          const {
            'line': '折线图',
            'scatter': '散点图',
            'pie': '饼图',
            'area': '面积图',
            'bar': '柱状图',
            'radar': '雷达图',
          }[kind]!,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < items.length; i++)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: Semantics(
                    selected: i == _selected,
                    button: true,
                    child: LuminaButton(
                      primary: i == _selected,
                      onPressed: () => setState(() {
                        _selected = i;
                        _inspection = null;
                      }),
                      child: Text(
                        '${kind == 'pie' ? '${i + 1}. ' : ''}${items[i]['label']}',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (kind != 'pie') ...[
          Text(
            kind == 'radar'
                ? '$yLabel：0 – ${_compact(math.max(1, high))}$unit · 所有系列同尺度'
                : '$yLabel：${_compact(lowerY)} – ${_compact(upperY)}$unit',
          ),
          if (kind != 'radar')
            Text(
              '$xLabel：${_compact(minX)} – ${_compact(maxX)}$xUnit${kind == 'bar' ? ' · 柱号见数据' : ''}',
            ),
        ],
        const SizedBox(height: 8),
        Semantics(
          label: '${item['label']}，点击图表查看数值；也可展开查看数据',
          child: SizedBox(
            key: const ValueKey('response-chart-surface'),
            height: kind == 'pie' || kind == 'radar' ? 230 : 230 + axisHeight,
            child: kind == 'bar'
                ? LuminaSurface(
                    padding: const EdgeInsets.all(10),
                    depth: LuminaSurfaceDepth.recessed,
                    radius: 12,
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: math.max(
                            constraints.maxWidth,
                            points.length * 32.0,
                          ),
                          child: chart,
                        ),
                      ),
                    ),
                  )
                : chart,
          ),
        ),
        if (kind == 'pie') Text('${item['label']}: ${total(item)}$unit'),
        if (_inspection != null)
          Semantics(
            liveRegion: true,
            child: Text(_inspection!, style: theme.textTheme.titleSmall),
          ),
        const Text('点击图表查看数值'),
        if (kind == 'radar')
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (var i = 0; i < points.length; i++)
                Text('${i + 1}. ${points[i]['label'] ?? points[i]['x']}'),
            ],
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('查看数据'),
          children: [
            for (var i = 0; i < points.length; i++)
              InkWell(
                onTap: () => inspect(i),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '${kind == 'radar' || kind == 'bar' ? '${i + 1}. ' : ''}${pointText(i)}',
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

String _compact(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsPrecision(3);
