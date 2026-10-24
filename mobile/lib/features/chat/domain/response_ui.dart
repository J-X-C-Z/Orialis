import 'dart:convert';

import 'response_svg.dart';
import 'response_visual_schema.dart';
import 'response_interactive_schema.dart';
import 'response_action_schema.dart';

/// A small native response vocabulary. Never evaluates HTML, scripts or URLs.
class ResponseUiDocument {
  const ResponseUiDocument({
    required this.version,
    required this.fallback,
    required this.blocks,
    this.title,
  });

  final int version;
  final String? title;
  final String fallback;
  final List<ResponseUiBlock> blocks;
  bool get supported => version == 1;

  static ResponseUiDocument? parse(String source) {
    if (source.length > 32768 || utf8.encode(source).length > 32768) {
      return null;
    }
    try {
      final data = jsonDecode(source);
      if (data is! Map<String, dynamic> ||
          data['version'] is! int ||
          data['version'] < 1 ||
          !_text(data['fallback'], 4000) ||
          !_optionalText(data['title'], 80)) {
        return null;
      }
      final version = data['version'] as int;
      if (version != 1) {
        return ResponseUiDocument(
          version: version,
          title: data['title'] as String?,
          fallback: data['fallback'] as String,
          blocks: const [],
        );
      }
      final blocks = data['blocks'];
      if (!_items(blocks)) return null;
      final parsed = <ResponseUiBlock>[];
      for (final raw in blocks as List) {
        if (raw is! Map<String, dynamic> ||
            !_optionalText(raw['title'], 80) ||
            !_optionalText(raw['unit'], 32) ||
            !_items(raw['items'])) {
          return null;
        }
        final type = raw['type'];
        final extended = visualResponseTypes.contains(type)
            ? validateVisualResponseBlock(raw)
            : interactiveResponseTypes.contains(type)
            ? validateInteractiveResponseBlock(raw)
            : actionResponseTypes.contains(type)
            ? validateActionResponseBlock(raw)
            : null;
        if (extended != null) {
          if (!extended) return null;
          parsed.add(
            ResponseUiBlock(
              type: type as String,
              title: raw['title'] as String?,
              unit: raw['unit'] as String?,
              items: const [],
              data: Map.unmodifiable(raw),
            ),
          );
          continue;
        }
        if (!const {
          'metrics',
          'chart',
          'tabs',
          'checklist',
          'choices',
          'svg',
        }.contains(type)) {
          return null;
        }
        final items = <ResponseUiItem>[];
        for (final item in raw['items'] as List) {
          if (item is! Map<String, dynamic> || !_text(item['label'], 120)) {
            return null;
          }
          switch (type) {
            case 'metrics':
              if (!_text(item['value'], 120) ||
                  !_optionalText(item['detail'], 240)) {
                return null;
              }
            case 'chart':
              if (item['value'] is! num || !(item['value'] as num).isFinite) {
                return null;
              }
            case 'tabs':
              if (!_text(item['content'], 4000)) return null;
            case 'checklist':
              if (item['checked'] is! bool) return null;
            case 'choices':
              if (!_text(item['prompt'], 1000)) return null;
            case 'svg':
              if (!ResponseSvg.isValid(item['source'])) return null;
          }
          items.add(
            ResponseUiItem(
              label: item['label'] as String,
              value: type == 'metrics' || type == 'chart'
                  ? item['value']
                  : null,
              detail: type == 'metrics' ? item['detail'] as String? : null,
              content: type == 'tabs' ? item['content'] as String : null,
              checked: type == 'checklist' ? item['checked'] as bool : false,
              prompt: type == 'choices' ? item['prompt'] as String : null,
              source: type == 'svg' ? item['source'] as String : null,
            ),
          );
        }
        parsed.add(
          ResponseUiBlock(
            type: type as String,
            title: raw['title'] as String?,
            unit: raw['unit'] as String?,
            items: List.unmodifiable(items),
          ),
        );
      }
      return ResponseUiDocument(
        version: version,
        title: data['title'] as String?,
        fallback: data['fallback'] as String,
        blocks: List.unmodifiable(parsed),
      );
    } on FormatException {
      return null;
    }
  }

  static bool _text(Object? value, int limit) =>
      value is String && value.trim().isNotEmpty && value.runes.length <= limit;
  static bool _optionalText(Object? value, int limit) =>
      value == null || _text(value, limit);
  static bool _items(Object? value) =>
      value is List && value.isNotEmpty && value.length <= 12;
}

class ResponseUiBlock {
  const ResponseUiBlock({
    required this.type,
    required this.items,
    this.title,
    this.unit,
    this.data = const {},
  });
  final String type;
  final String? title;
  final String? unit;
  final List<ResponseUiItem> items;
  final Map<String, dynamic> data;
}

class ResponseUiItem {
  const ResponseUiItem({
    required this.label,
    this.value,
    this.detail,
    this.content,
    this.prompt,
    this.source,
    this.checked = false,
  });
  final String label;
  final Object? value;
  final String? detail;
  final String? content;
  final String? prompt;
  final String? source;
  final bool checked;
}
