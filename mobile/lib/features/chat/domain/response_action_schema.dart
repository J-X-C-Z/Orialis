const actionResponseTypes = {'media', 'actions', 'agenda'};

bool validateActionResponseBlock(Map<String, dynamic> raw) {
  final items = raw['items'];
  if (items is! List || items.isEmpty || items.length > 12) return false;
  final ids = <String>{};
  for (final item in items) {
    if (item is! Map<String, dynamic> ||
        !_text(item['label'], 120) ||
        !_id(item['id']) ||
        !ids.add(item['id'] as String)) {
      return false;
    }
    if (raw['type'] == 'media') {
      if (!_text(item['mimeType'], 120) || !_optional(item['name'], 240)) {
        return false;
      }
    } else if (raw['type'] == 'actions' || raw['type'] == 'agenda') {
      final agenda = raw['type'] == 'agenda';
      if (agenda && item.containsKey('kind')) return false;
      if (!_text(item['title'], 240) ||
          !_optional(item['notes'], 4000) ||
          !_optional(item['location'], 240)) {
        return false;
      }
      if (!agenda && item['kind'] == 'task') {
        if (item['due'] != null && !_date(item['due'])) return false;
      } else if (agenda || item['kind'] == 'schedule') {
        if (!_timestamp(item['startAt']) || !_timestamp(item['endAt'])) {
          return false;
        }
        if (!DateTime.parse(item['startAt'] as String)
            .isBefore(DateTime.parse(item['endAt'] as String))) {
          return false;
        }
      } else {
        return false;
      }
    } else {
      return false;
    }
  }
  return true;
}

bool _text(Object? value, int max) =>
    value is String && value.trim().isNotEmpty && value.runes.length <= max;
bool _optional(Object? value, int max) => value == null || _text(value, max);
bool _id(Object? value) =>
    value is String && RegExp(r'^[a-zA-Z0-9_-]{1,160}$').hasMatch(value);

bool _date(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return false;
  }
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.toIso8601String().startsWith(value);
}

bool _timestamp(Object? value) {
  if (value is! String ||
      value.length > 40 ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?(?:Z|[+-]\d{2}:\d{2})$',
      ).hasMatch(value)) {
    return false;
  }
  if (!_date(value.substring(0, 10))) return false;
  final hour = int.parse(value.substring(11, 13));
  final minute = int.parse(value.substring(14, 16));
  if (hour > 23 || minute > 59) return false;
  if (value.length > 17 &&
      value[16] == ':' &&
      int.parse(value.substring(17, 19)) > 59) {
    return false;
  }
  if (!value.endsWith('Z')) {
    final offset = value.substring(value.length - 5);
    if (int.parse(offset.substring(0, 2)) > 23 ||
        int.parse(offset.substring(3, 5)) > 59) {
      return false;
    }
  }
  return DateTime.tryParse(value) != null;
}
