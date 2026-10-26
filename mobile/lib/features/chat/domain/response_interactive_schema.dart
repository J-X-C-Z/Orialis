const interactiveResponseTypes = {
  'form',
  'table',
  'sources',
  'diff',
  'accordion',
};

bool _text(Object? value, int limit, {bool empty = false}) =>
    value is String &&
    (empty || value.trim().isNotEmpty) &&
    value.runes.length <= limit;

bool _optionalText(Object? value, int limit) =>
    value == null || _text(value, limit);

bool _number(Object? value, double limit) =>
    value is num && value.isFinite && value.abs() <= limit;

bool responseDateIsValid(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final date = DateTime.tryParse(value);
  return date != null &&
      date.year >= 1 &&
      date.toIso8601String().substring(0, 10) == value;
}

bool responseSourceUrlIsValid(Object? value) {
  if (!_text(value, 2000) || RegExp(r'\s').hasMatch(value as String)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
      const {'http', 'https'}.contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

bool validateInteractiveResponseBlock(Map<String, dynamic> raw) {
  final items = raw['items'];
  final type = raw['type'];
  if (!interactiveResponseTypes.contains(type) ||
      items is! List ||
      items.isEmpty ||
      items.length > 12) {
    return false;
  }
  if (type == 'form' && !_optionalText(raw['prompt'], 1000)) return false;
  final columns = raw['columns'];
  if (type == 'table' &&
      (columns is! List ||
          columns.isEmpty ||
          columns.length > 8 ||
          columns.any((value) => !_text(value, 120)))) {
    return false;
  }
  final ids = <String>{};
  for (final item in items) {
    if (item is! Map<String, dynamic> || !_text(item['label'], 120)) {
      return false;
    }
    switch (type) {
      case 'form':
        final id = item['id'];
        if (id is! String ||
            !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$').hasMatch(id) ||
            !ids.add(id) ||
            (item['required'] != null && item['required'] is! bool)) {
          return false;
        }
        final kind = item['kind'];
        final value = item['value'];
        if (!const {
          'text',
          'date',
          'select',
          'multiselect',
          'slider',
        }.contains(kind)) {
          return false;
        }
        if (kind == 'text' &&
            value != null &&
            !_text(value, 1000, empty: true)) {
          return false;
        }
        if (kind == 'date' &&
            value != null &&
            (value is! String || !responseDateIsValid(value))) {
          return false;
        }
        if (kind == 'select' || kind == 'multiselect') {
          final options = item['options'];
          if (options is! List ||
              options.isEmpty ||
              options.length > 12 ||
              options.any((option) => !_text(option, 120)) ||
              options.toSet().length != options.length) {
            return false;
          }
          if (kind == 'select' && value != null && !options.contains(value)) {
            return false;
          }
          if (kind == 'multiselect' &&
              value != null &&
              (value is! List ||
                  value.length > 12 ||
                  value.toSet().length != value.length ||
                  value.any((entry) => !options.contains(entry)))) {
            return false;
          }
        }
        if (kind == 'slider') {
          final min = item['min'];
          final max = item['max'];
          if (!_number(min, 1e6) ||
              !_number(max, 1e6) ||
              min >= max ||
              (value != null &&
                  (!_number(value, 1e6) || value < min || value > max))) {
            return false;
          }
        }
      case 'table':
        final cells = item['cells'];
        if (cells is! List ||
            cells.length != (columns as List).length ||
            cells.any(
              (value) =>
                  !_text(value, 1000, empty: true) && !_number(value, 1e12),
            )) {
          return false;
        }
      case 'sources':
        if (!responseSourceUrlIsValid(item['url']) ||
            !_optionalText(item['excerpt'], 4000) ||
            !_optionalText(item['sourceId'], 120)) {
          return false;
        }
      case 'diff':
        if (!_text(item['before'], 4000, empty: true) ||
            !_text(item['after'], 4000, empty: true)) {
          return false;
        }
      case 'accordion':
        if (!_text(item['content'], 4000)) return false;
    }
  }
  return true;
}

/// Human spreadsheet export; strings cannot become executable formulas.
String responseTableCsv(List<String> columns, List<List<Object?>> rows) {
  String cell(Object? value) {
    var text = '$value';
    if (value is String && RegExp(r'^[\s]*[=+\-@]').hasMatch(text)) {
      text = "'$text";
    }
    return '"${text.replaceAll('"', '""')}"';
  }

  return [
    columns.map(cell).join(','),
    ...rows.map((row) => row.map(cell).join(',')),
  ].join('\r\n');
}

String? responseFormError(
  Map<String, dynamic> data,
  Map<String, Object?> values,
) {
  for (final item in data['items'] as List) {
    final error = responseFormFieldError(item, values[item['id']]);
    if (error != null) return error;
  }
  return null;
}

String? responseFormFieldError(Map<String, dynamic> item, Object? value) {
  final empty =
      value == null ||
      (value is String && value.trim().isEmpty) ||
      (value is List && value.isEmpty);
  if (item['required'] == true && empty) return '请填写${item['label']}';
  if (!empty &&
      item['kind'] == 'date' &&
      (value is! String || !responseDateIsValid(value))) {
    return '${item['label']}请使用有效日期（YYYY-MM-DD）';
  }
  return null;
}

String responseFormPrompt(
  Map<String, dynamic> data,
  Map<String, Object?> values,
) {
  final lines = <String>[data['prompt'] as String? ?? '请根据以下信息继续：'];
  for (final item in data['items'] as List) {
    final value = values[item['id']];
    lines.add(
      '${item['label']}：${value is List ? value.join('、') : value ?? '未填写'}',
    );
  }
  return lines.join('\n');
}
