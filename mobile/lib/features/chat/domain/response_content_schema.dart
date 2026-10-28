const contentResponseTypes = {
  'callout',
  'steps',
  'comparison',
  'facts',
  'code',
};

bool _text(Object? value, int limit, {bool empty = false}) =>
    value is String &&
    (empty || value.trim().isNotEmpty) &&
    value.runes.length <= limit;

bool _optionalText(Object? value, int limit) =>
    value == null || _text(value, limit);

bool _boundedItems(Object? value) =>
    value is List && value.isNotEmpty && value.length <= 12;

bool validateContentResponseBlock(Map<String, dynamic> raw) {
  final type = raw['type'];
  final items = raw['items'];
  if (!contentResponseTypes.contains(type) || !_boundedItems(items)) {
    return false;
  }
  switch (type) {
    case 'callout':
      return items.every(
        (item) =>
            item is Map<String, dynamic> &&
            _text(item['label'], 120) &&
            _text(item['content'], 4000) &&
            (item['tone'] == null ||
                const {
                  'info',
                  'success',
                  'warning',
                  'critical',
                }.contains(item['tone'])),
      );
    case 'steps':
      return items.every(
        (item) =>
            item is Map<String, dynamic> &&
            _text(item['label'], 120) &&
            _optionalText(item['detail'], 1000) &&
            (item['status'] == null ||
                const {'pending', 'current', 'done'}.contains(item['status'])),
      );
    case 'comparison':
      final columns = raw['columns'];
      final recommended = raw['recommendedIndex'];
      if (columns is! List ||
          columns.length < 2 ||
          columns.length > 4 ||
          columns.any((value) => !_text(value, 120)) ||
          columns.toSet().length != columns.length ||
          (recommended != null &&
              (recommended is! int ||
                  recommended < 0 ||
                  recommended >= columns.length))) {
        return false;
      }
      return items.every(
        (item) =>
            item is Map<String, dynamic> &&
            _text(item['label'], 120) &&
            item['values'] is List &&
            (item['values'] as List).length == columns.length &&
            (item['values'] as List).every(
              (value) => _text(value, 1000, empty: true),
            ),
      );
    case 'facts':
      return items.every(
        (item) =>
            item is Map<String, dynamic> &&
            _text(item['label'], 120) &&
            _text(item['value'], 1000) &&
            _optionalText(item['detail'], 240),
      );
    case 'code':
      return items.every(
        (item) =>
            item is Map<String, dynamic> &&
            _text(item['label'], 120) &&
            _text(item['source'], 16000) &&
            _optionalText(item['language'], 32),
      );
  }
  return false;
}
