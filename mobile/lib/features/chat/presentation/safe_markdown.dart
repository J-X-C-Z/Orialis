import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:url_launcher/url_launcher.dart';

import '../domain/response_ui.dart';
import 'response_ui_view.dart';

enum MarkdownBlockType {
  heading,
  paragraph,
  code,
  bullets,
  ordered,
  table,
  quote,
  divider,
}

final RegExp _fencePattern = RegExp(r'^\s*```\s*([\w+-]*)\s*$');
final RegExp _headingPattern = RegExp(r'^\s*(#{1,6})\s+(.+?)\s*$');
final RegExp _listItemPattern = RegExp(r'^\s*([-*+] |\d+[.)] )(.+)$');
final RegExp _listBulletPattern = RegExp(r'^\s*([-*+] |\d+[.)] )');
final RegExp _orderedMarkerPattern = RegExp(r'^\d');
final RegExp _quotePattern = RegExp(r'^\s*> ?');
final RegExp _dividerPattern = RegExp(
  r'^\s{0,3}(?:\*\s*){3,}$|^\s{0,3}(?:-\s*){3,}$|^\s{0,3}(?:_\s*){3,}$',
);
final RegExp _tableSeparatorCellPattern = RegExp(r'^:?-{3,}:?$');
final RegExp _tableEdgePattern = RegExp(r'^\|');
final RegExp _tableTrailingPipePattern = RegExp(r'\|$');
final RegExp _inlineSpanPattern = RegExp(
  r'(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^\)]+\)|\*[^*\n]+\*)',
);

/// Text actions keep ordinary Markdown intact and use the authored summary.
String responseUiPlainText(String source) {
  final fences = RegExp(
    r'^[ \t]*```[ \t]*([\w+-]*)[ \t]*(?=\r?$)',
    multiLine: true,
  ).allMatches(source).toList();
  final result = StringBuffer();
  var cursor = 0;
  for (var index = 0; index < fences.length; index++) {
    final opening = fences[index];
    var closingIndex = index + 1;
    while (closingIndex < fences.length &&
        fences[closingIndex].group(1) != '') {
      closingIndex++;
    }
    if (closingIndex == fences.length) break;
    final closing = fences[closingIndex];
    if (opening.group(1) == 'orialis-ui') {
      final lines = source
          .substring(opening.end, closing.start)
          .replaceAll('\r\n', '\n')
          .split('\n');
      final document = ResponseUiDocument.parse(
        lines.sublist(1, lines.length - 1).join('\n'),
      );
      if (document != null) {
        result.write(source.substring(cursor, opening.start));
        result.write(document.fallback);
        cursor = closing.end;
      }
    }
    index = closingIndex;
  }
  result.write(source.substring(cursor));
  return result.toString();
}

/// Completed chat bubbles re-parse on every parent rebuild. Keep a tiny LRU so
/// long conversations do not pay full Markdown cost on each stream tick or
/// scroll-driven rebuild of neighboring rows.
final Map<String, List<MarkdownBlock>> _markdownBlockCache = {};
const int _markdownBlockCacheLimit = 48;

List<MarkdownBlock> _parseMarkdownCached(String source) {
  final cached = _markdownBlockCache.remove(source);
  if (cached != null) {
    _markdownBlockCache[source] = cached;
    return cached;
  }
  final blocks = MarkdownBlock.parse(source);
  if (source.length <= 8000) {
    _markdownBlockCache[source] = blocks;
    if (_markdownBlockCache.length > _markdownBlockCacheLimit) {
      _markdownBlockCache.remove(_markdownBlockCache.keys.first);
    }
  }
  return blocks;
}

class MarkdownBlock {
  const MarkdownBlock({
    required this.type,
    required this.lines,
    this.level = 0,
    this.startNumber = 1,
    this.language,
    this.fenceClosed = true,
  });
  final MarkdownBlockType type;
  final List<String> lines;
  final int level;
  final int startNumber;
  final String? language;
  final bool fenceClosed;

  static List<MarkdownBlock> parse(String source) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final blocks = <MarkdownBlock>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index];
      if (line.trim().isEmpty) {
        index++;
        continue;
      }
      final fence = _fencePattern.firstMatch(line);
      if (fence != null) {
        final code = <String>[];
        final responseUi = fence.group(1) == 'orialis-ui';
        index++;
        while (index < lines.length &&
            !(responseUi
                ? lines[index].trim() == '```'
                : lines[index].trimLeft().startsWith('```'))) {
          code.add(lines[index]);
          index++;
        }
        final closed = index < lines.length;
        if (closed) {
          index++;
        }
        blocks.add(
          MarkdownBlock(
            type: MarkdownBlockType.code,
            lines: code,
            language: fence.group(1),
            fenceClosed: closed,
          ),
        );
        continue;
      }
      final heading = _headingPattern.firstMatch(line);
      if (heading != null) {
        blocks.add(
          MarkdownBlock(
            type: MarkdownBlockType.heading,
            lines: [heading.group(2)!],
            level: heading.group(1)!.length,
          ),
        );
        index++;
        continue;
      }
      if (_isTableStart(lines, index)) {
        final table = <String>[lines[index]];
        index += 2;
        while (index < lines.length &&
            lines[index].contains('|') &&
            lines[index].trim().isNotEmpty) {
          table.add(lines[index]);
          index++;
        }
        blocks.add(MarkdownBlock(type: MarkdownBlockType.table, lines: table));
        continue;
      }
      if (_dividerPattern.hasMatch(line)) {
        blocks.add(
          const MarkdownBlock(type: MarkdownBlockType.divider, lines: []),
        );
        index++;
        continue;
      }
      if (_quotePattern.hasMatch(line)) {
        final quote = <String>[];
        while (index < lines.length && _quotePattern.hasMatch(lines[index])) {
          quote.add(lines[index].replaceFirst(_quotePattern, ''));
          index++;
        }
        blocks.add(MarkdownBlock(type: MarkdownBlockType.quote, lines: quote));
        continue;
      }
      final listMatch = _listItemPattern.firstMatch(line);
      if (listMatch != null) {
        final ordered = _orderedMarkerPattern.hasMatch(listMatch.group(1)!);
        final startNumber = ordered
            ? int.tryParse(RegExp(r'^\d+').stringMatch(listMatch.group(1)!)!) ??
                  1
            : 1;
        final items = <String>[];
        while (index < lines.length) {
          final item = _listItemPattern.firstMatch(lines[index]);
          if (item == null ||
              _orderedMarkerPattern.hasMatch(item.group(1)!) != ordered) {
            break;
          }
          items.add(item.group(2)!);
          index++;
        }
        blocks.add(
          MarkdownBlock(
            type: ordered
                ? MarkdownBlockType.ordered
                : MarkdownBlockType.bullets,
            lines: items,
            startNumber: startNumber,
          ),
        );
        continue;
      }
      final paragraph = <String>[line.trim()];
      index++;
      while (index < lines.length &&
          lines[index].trim().isNotEmpty &&
          !lines[index].trimLeft().startsWith('#') &&
          !lines[index].trimLeft().startsWith('```') &&
          !_isTableStart(lines, index) &&
          !_quotePattern.hasMatch(lines[index]) &&
          !_dividerPattern.hasMatch(lines[index]) &&
          !_listBulletPattern.hasMatch(lines[index])) {
        paragraph.add(lines[index].trim());
        index++;
      }
      blocks.add(
        MarkdownBlock(type: MarkdownBlockType.paragraph, lines: paragraph),
      );
    }
    return blocks;
  }

  static bool _isTableStart(List<String> lines, int index) {
    if (index + 1 >= lines.length || !lines[index].contains('|')) return false;
    final separator = lines[index + 1].split('|').every((cell) {
      final value = cell.trim();
      return value.isEmpty || _tableSeparatorCellPattern.hasMatch(value);
    });
    return separator && lines[index + 1].contains('-');
  }
}

/// Small, dependency-free Markdown renderer for agent content.
///
/// It intentionally does not interpret HTML, raw URLs, or arbitrary inline
/// widgets. Malformed input is rendered as selectable plain text, which is a
/// safe and useful fallback for older or experimental agent messages.
/// Authored HTTP(S) links open externally only when tapped.
class SafeMarkdownView extends StatelessWidget {
  const SafeMarkdownView({
    required this.source,
    this.fallback = false,
    this.allowResponseUi = false,
    this.onPromptSelected,
    super.key,
  });
  final String source;
  final bool fallback;
  final bool allowResponseUi;
  final ValueChanged<String>? onPromptSelected;

  @override
  Widget build(BuildContext context) {
    if (source.trim().isEmpty) return const SizedBox.shrink();
    final blocks = fallback
        ? const <MarkdownBlock>[]
        : _parseMarkdownCached(source);
    if (fallback || blocks.isEmpty) return LuminaSelectableText(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          _BlockView(
            block: block,
            allowResponseUi: allowResponseUi,
            onPromptSelected: onPromptSelected,
          ),
      ],
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView({
    required this.block,
    required this.allowResponseUi,
    this.onPromptSelected,
  });
  final MarkdownBlock block;
  final bool allowResponseUi;
  final ValueChanged<String>? onPromptSelected;

  @override
  Widget build(BuildContext context) {
    switch (block.type) {
      case MarkdownBlockType.heading:
        final style = switch (block.level) {
          1 => LuminaTheme.of(context).textTheme.headlineSmall,
          2 => LuminaTheme.of(context).textTheme.titleLarge,
          _ => LuminaTheme.of(context).textTheme.titleMedium,
        };
        return Padding(
          padding: const EdgeInsets.only(top: LuminaSpacing.compact, bottom: 4),
          child: _InlineText(
            text: block.lines.single,
            style: style.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      case MarkdownBlockType.code:
        if (allowResponseUi && block.language == 'orialis-ui') {
          if (!block.fenceClosed) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('正在生成交互内容…'),
            );
          }
          final source = block.lines.join('\n');
          final document = ResponseUiDocument.parse(source);
          if (document != null) {
            return ResponseUiView(
              key: ValueKey(source),
              document: document,
              onPromptSelected: onPromptSelected,
            );
          }
        }
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(LuminaSpacing.item),
          decoration: BoxDecoration(
            color: LuminaTheme.of(context).colors.recessedSurface,
            borderRadius: BorderRadius.circular(LuminaRadius.attachment),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    block.language?.isNotEmpty == true ? block.language! : '代码',
                  ),
                  LuminaButton(
                    child: const Text('复制代码'),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: block.lines.join('\n')),
                      );
                      if (context.mounted) showLuminaToast(context, '代码已复制');
                    },
                  ),
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: LuminaSelectableText(
                  block.lines.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        );
      case MarkdownBlockType.bullets:
      case MarkdownBlockType.ordered:
        var markerWidth = 22.0;
        if (block.type == MarkdownBlockType.ordered) {
          final marker = TextPainter(
            text: TextSpan(
              text: '${block.startNumber + block.lines.length - 1}.',
              style: DefaultTextStyle.of(context).style,
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          if (marker.width + 8 > markerWidth) markerWidth = marker.width + 8;
          marker.dispose();
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < block.lines.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: markerWidth,
                        child: Text(
                          block.type == MarkdownBlockType.bullets
                              ? '•'
                              : '${block.startNumber + index}.',
                          softWrap: false,
                        ),
                      ),
                      Expanded(child: _InlineText(text: block.lines[index])),
                    ],
                  ),
                ),
            ],
          ),
        );
      case MarkdownBlockType.table:
        final rows = block.lines.map(_tableCells).toList();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside: BorderSide(
                color: LuminaTheme.of(context).colors.outline,
              ),
            ),
            children: [
              for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                TableRow(
                  decoration: rowIndex == 0
                      ? BoxDecoration(
                          color: LuminaTheme.of(context).colors.accentSoft,
                        )
                      : null,
                  children: [
                    for (var column = 0; column < rows.first.length; column++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          child: _InlineText(
                            text: column < rows[rowIndex].length
                                ? rows[rowIndex][column]
                                : '',
                            style: rowIndex == 0
                                ? const TextStyle(fontWeight: FontWeight.w600)
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      case MarkdownBlockType.paragraph:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _InlineText(text: block.lines.join('\n')),
        );
      case MarkdownBlockType.quote:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsetsDirectional.only(start: 12),
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(
                color: LuminaTheme.of(context).colors.outline,
                width: 3,
              ),
            ),
          ),
          child: _InlineText(
            text: block.lines.join('\n'),
            style: TextStyle(color: LuminaTheme.of(context).colors.muted),
          ),
        );
      case MarkdownBlockType.divider:
        return Container(
          height: 1,
          margin: const EdgeInsets.symmetric(vertical: 16),
          color: LuminaTheme.of(context).colors.outline,
        );
    }
  }
}

class _InlineText extends StatefulWidget {
  const _InlineText({required this.text, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<_InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<_InlineText> {
  final _links = <TapGestureRecognizer>[];

  void _disposeLinks() {
    for (final link in _links) {
      link.dispose();
    }
    _links.clear();
  }

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  Future<void> _openLink(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on Object {
      // Keep the reply readable when no browser is available.
    }
    if (mounted) showLuminaToast(context, '链接未能打开，可以长按消息复制链接');
  }

  @override
  Widget build(BuildContext context) {
    _disposeLinks();
    final text = widget.text;
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final match in _inlineSpanPattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final value = match.group(0)!;
      if (value.startsWith('**')) {
        spans.add(
          TextSpan(
            text: value.substring(2, value.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (value.startsWith('`')) {
        spans.add(
          TextSpan(
            text: value.substring(1, value.length - 1),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        );
      } else if (value.startsWith('[')) {
        final label = value.substring(1, value.indexOf(']'));
        final target = value.substring(
          value.indexOf('](') + 2,
          value.length - 1,
        );
        final uri = Uri.tryParse(target);
        final allowed =
            uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty;
        final recognizer = allowed
            ? (TapGestureRecognizer()..onTap = () => _openLink(uri))
            : null;
        if (recognizer != null) _links.add(recognizer);
        spans.add(
          TextSpan(
            text: label,
            recognizer: recognizer,
            mouseCursor: allowed ? SystemMouseCursors.click : null,
            style: allowed
                ? TextStyle(
                    color: LuminaTheme.of(context).colors.accent,
                    decoration: TextDecoration.underline,
                  )
                : null,
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: value.substring(1, value.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return RichText(
      textScaler: MediaQuery.textScalerOf(context),
      text: TextSpan(
        style: DefaultTextStyle.of(context).style
            .copyWith(height: 1.6)
            .merge(widget.style),
        children: spans,
      ),
    );
  }
}

List<String> _tableCells(String line) => line
    .trim()
    .replaceFirst(_tableEdgePattern, '')
    .replaceFirst(_tableTrailingPipePattern, '')
    .split('|')
    .map((value) => value.trim())
    .toList();
