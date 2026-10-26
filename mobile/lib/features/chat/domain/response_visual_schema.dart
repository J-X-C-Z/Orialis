const visualResponseTypes = {
  'diagram',
  'math',
  'plot',
  'timeline',
  'simulation',
  'progress',
  'heatmap',
};

bool _text(Object? value, int limit) =>
    value is String && value.trim().isNotEmpty && value.runes.length <= limit;
bool _optionalText(Object? value, int limit) =>
    value == null || _text(value, limit);
bool _number(Object? value, double min, double max) =>
    value is num && value.isFinite && value >= min && value <= max;

/// Validates drawing and teaching data before native widgets consume it.
bool validateVisualResponseBlock(Map<String, dynamic> raw) {
  final type = raw['type'];
  final items = raw['items'];
  if (!visualResponseTypes.contains(type) ||
      items is! List ||
      items.isEmpty ||
      items.length > 12 ||
      items.any(
        (item) => item is! Map<String, dynamic> || !_text(item['label'], 120),
      )) {
    return false;
  }
  switch (type) {
    case 'diagram':
      if (raw['layout'] != null &&
          !const {'flow', 'mindmap', 'graph'}.contains(raw['layout'])) {
        return false;
      }
      final ids = <String>{};
      for (final item in items) {
        if (!_text(item['id'], 40) ||
            !ids.add(item['id'] as String) ||
            !_optionalText(item['detail'], 1000) ||
            !_optionalText(item['parent'], 40)) {
          return false;
        }
      }
      final parents = <String, String>{};
      for (final item in items) {
        final parent = item['parent'];
        if (parent == null) continue;
        if (!ids.contains(parent) || parent == item['id']) return false;
        parents[item['id'] as String] = parent as String;
      }
      for (final id in ids) {
        final visited = <String>{id};
        var next = parents[id];
        while (next != null) {
          if (!visited.add(next)) return false;
          next = parents[next];
        }
      }
      final edges = raw['edges'];
      if (edges != null) {
        if (edges is! List || edges.length > 24) return false;
        for (final edge in edges) {
          if (edge is! Map<String, dynamic> ||
              !ids.contains(edge['from']) ||
              !ids.contains(edge['to']) ||
              !_optionalText(edge['label'], 80)) {
            return false;
          }
        }
      }
      return true;
    case 'math':
      return items.every((item) => _text(item['source'], 4000));
    case 'plot':
      final kind = raw['kind'];
      if (!const {
            'line',
            'scatter',
            'pie',
            'area',
            'bar',
            'radar',
          }.contains(kind) ||
          !_optionalText(raw['xLabel'], 80) ||
          !_optionalText(raw['yLabel'], 80) ||
          !_optionalText(raw['xUnit'], 32)) {
        return false;
      }
      var pieTotal = 0.0;
      List<dynamic>? radarAxes;
      for (final item in items) {
        final points = item['points'];
        if (points is! List || points.isEmpty || points.length > 120) {
          return false;
        }
        if (kind == 'radar' && points.length < 3) {
          return false;
        }
        final coordinates = <num>{};
        num? previousX;
        for (final point in points) {
          if (point is! Map<String, dynamic> ||
              !_number(point['x'], -1e6, 1e6) ||
              !_number(
                point['y'],
                kind == 'pie' || kind == 'radar' ? 0 : -1e6,
                1e6,
              ) ||
              !_optionalText(point['label'], 120)) {
            return false;
          }
          final x = point['x'] as num;
          if (const {'area', 'bar', 'radar'}.contains(kind) &&
              !coordinates.add(x)) {
            return false;
          }
          if (kind == 'area' && previousX != null && x <= previousX) {
            return false;
          }
          previousX = x;
          pieTotal += (point['y'] as num).toDouble();
        }
        if (kind == 'radar') {
          final axes = radarAxes;
          if (axes != null &&
              (points.length != axes.length ||
                  List.generate(points.length, (i) => i).any(
                    (i) =>
                        points[i]['x'] != axes[i]['x'] ||
                        points[i]['label'] != axes[i]['label'],
                  ))) {
            return false;
          }
          radarAxes ??= points;
        }
      }
      return kind != 'pie' || pieTotal > 0;
    case 'progress':
      if (raw['style'] != null &&
          !const {'linear', 'ring'}.contains(raw['style'])) {
        return false;
      }
      return items.every((item) {
        final max = item['max'] ?? 100;
        return _number(max, double.minPositive, 1e6) &&
            _number(item['value'], 0, (max as num).toDouble()) &&
            _optionalText(item['detail'], 240);
      });
    case 'heatmap':
      final dates = <String>{};
      return items.every((item) {
        final date = item['date'];
        if (date is! String ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
            !_number(item['value'], 0, 1e6) ||
            !dates.add(date)) {
          return false;
        }
        // DateTime.parse normalizes overflow dates; require an exact calendar date.
        final parsed = DateTime.tryParse(date);
        return parsed != null &&
            parsed.year >= 1 &&
            parsed.toIso8601String().substring(0, 10) == date;
      });
    case 'timeline':
      return items.every(
        (item) =>
            _optionalText(item['detail'], 1000) &&
            (item['time'] == null ||
                (_text(item['time'], 80) &&
                    DateTime.tryParse(item['time'] as String) != null)),
      );
    case 'simulation':
      if (items.length != 1) return false;
      final item = items.single;
      return const {'fourier', 'sine'}.contains(item['kind']) &&
          (item['terms'] == null ||
              (item['terms'] is int && _number(item['terms'], 1, 25))) &&
          (item['amplitude'] == null || _number(item['amplitude'], 0.1, 5)) &&
          (item['frequency'] == null || _number(item['frequency'], 0.1, 5));
  }
  return false;
}
