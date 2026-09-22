import '../../../app/design/design_components.dart';

enum MarkdownBlockType { heading, paragraph, code, bullets, ordered, table }

class MarkdownBlock {
  const MarkdownBlock({
    required this.type,
    required this.lines,
    this.level = 0,
    this.language,
  });
  final MarkdownBlockType type;
  final List<String> lines;
  final int level;
  final String? language;

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
      final fence = RegExp(r'^\s*```\s*([\w+-]*)\s*$').firstMatch(line);
      if (fence != null) {
        final code = <String>[];
        index++;
        while (index < lines.length &&
            !lines[index].trimLeft().startsWith('```')) {
          code.add(lines[index]);
          index++;
        }
        if (index < lines.length) {
          index++;
        }
        blocks.add(
          MarkdownBlock(
            type: MarkdownBlockType.code,
            lines: code,
            language: fence.group(1),
          ),
        );
        continue;
      }
      final heading = RegExp(r'^\s*(#{1,6})\s+(.+?)\s*$').firstMatch(line);
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
      final listMatch = RegExp(r'^\s*([-*+] |\d+[.)] )(.+)$').firstMatch(line);
      if (listMatch != null) {
        final ordered = RegExp(r'^\d').hasMatch(listMatch.group(1)!);
        final items = <String>[];
        while (index < lines.length) {
          final item = RegExp(
            r'^\s*([-*+] |\d+[.)] )(.+)$',
          ).firstMatch(lines[index]);
          if (item == null ||
              RegExp(r'^\d').hasMatch(item.group(1)!) != ordered) {
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
          !RegExp(r'^\s*([-*+] |\d+[.)] )').hasMatch(lines[index])) {
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
      return value.isEmpty || RegExp(r'^:?-{3,}:?$').hasMatch(value);
    });
    return separator && lines[index + 1].contains('-');
  }
}

/// Small, dependency-free Markdown renderer for agent content.
///
/// It intentionally does not interpret HTML, raw URLs, or arbitrary inline
/// widgets. Malformed input is rendered as selectable plain text, which is a
/// safe and useful fallback for older or experimental agent messages.
class SafeMarkdownView extends StatelessWidget {
  const SafeMarkdownView({
    required this.source,
    this.fallback = false,
    super.key,
  });
  final String source;
  final bool fallback;

  @override
  Widget build(BuildContext context) {
    if (source.trim().isEmpty) return const SizedBox.shrink();
    final blocks = fallback
        ? const <MarkdownBlock>[]
        : MarkdownBlock.parse(source);
    if (fallback || blocks.isEmpty) return LuminaSelectableText(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final block in blocks) _BlockView(block: block)],
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block});
  final MarkdownBlock block;

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
          padding: const EdgeInsets.only(top: AppSpacing.compact, bottom: 4),
          child: _InlineText(
            text: block.lines.single,
            style: style.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      case MarkdownBlockType.code:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(AppSpacing.item),
          decoration: BoxDecoration(
            color: LuminaTheme.of(context).colors.accentSoft,
            borderRadius: BorderRadius.circular(AppRadius.attachment),
          ),
          child: LuminaSelectableText(
            block.lines.join('\n'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.45,
            ),
          ),
        );
      case MarkdownBlockType.bullets:
      case MarkdownBlockType.ordered:
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
                        width: 22,
                        child: Text(
                          block.type == MarkdownBlockType.bullets
                              ? '•'
                              : '${index + 1}.',
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
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: _InlineText(text: block.lines.join('\n')),
        );
    }
  }
}

class _InlineText extends StatelessWidget {
  const _InlineText({required this.text, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^\)]+\))');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
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
      } else {
        final label = value.substring(1, value.indexOf(']'));
        spans.add(
          TextSpan(
            text: label,
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style.merge(style),
        children: spans,
      ),
    );
  }
}

List<String> _tableCells(String line) => line
    .trim()
    .replaceFirst(RegExp(r'^\|'), '')
    .replaceFirst(RegExp(r'\|$'), '')
    .split('|')
    .map((value) => value.trim())
    .toList();
