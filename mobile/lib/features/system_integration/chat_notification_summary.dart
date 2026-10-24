import 'package:flutter/widgets.dart' show StringCharacters;

import '../chat/presentation/safe_markdown.dart';

/// Extract a readable topic and a short takeaway without a network round trip.
({String title, String body}) summarizeChatNotification({
  required String content,
  String? userPrompt,
  String? conversationTitle,
  bool hasAttachments = false,
}) {
  final blocks = MarkdownBlock.parse(responseUiPlainText(content));
  final headings = blocks
      .where((block) => block.type == MarkdownBlockType.heading)
      .map((block) => _plain(block.lines.join(' ')));
  final prose = blocks
      .where(
        (block) => !const {
          MarkdownBlockType.heading,
          MarkdownBlockType.code,
          MarkdownBlockType.divider,
        }.contains(block.type),
      )
      .expand(
        (block) => block.type == MarkdownBlockType.paragraph
            ? [block.lines.join(' ')]
            : block.lines,
      )
      .map(_plain)
      .where((line) => line.isNotEmpty)
      .toList();
  final topic = [
    ...headings,
    ?userPrompt,
    ?conversationTitle,
    ...prose,
  ].map(_topic).whereType<String>().firstOrNull;
  final points = prose
      .expand((line) => line.split(RegExp(r'(?<=[。！？!?；;])\s*|(?<=\.)\s+')))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !_generic(line))
      .take(2)
      .toList();
  final fallback = hasAttachments
      ? '收到附件，点击查看详情'
      : blocks.any((block) => block.type == MarkdownBlockType.code)
      ? '助手发来一段代码，点击查看详情'
      : headings.firstOrNull ?? '回复已送达，点击查看详情';
  final body = points.isEmpty
      ? fallback
      : points.indexed
            .map((point) {
              final (index, text) = point;
              if (index == points.length - 1 ||
                  RegExp(r'[。！？!?；;.]$').hasMatch(text)) {
                return text;
              }
              return '$text；';
            })
            .join(' ');
  return (
    title: _shorten(topic ?? (hasAttachments ? '会话附件' : '会话回复'), 26),
    body: _shorten(body, 100),
  );
}

String _plain(String source) => source
    .replaceAllMapped(
      RegExp(r'!?\[([^\]]+)\]\([^)]+\)'),
      (match) => match.group(1)!,
    )
    .replaceAll(RegExp(r'\*\*|__|`|\*'), '')
    .replaceAll(RegExp(r'https?://\S+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceFirst(RegExp(r'^(?:好的|收到|没问题|当然可以)[，,。！!：:\s]+'), '')
    .trim();

bool _generic(String text) => const {
  '新消息',
  '收到一条新消息',
  '新会话',
  '默认会话',
  '主会话',
  '默认',
  'mac 电脑',
  'azure 服务器',
  'windows 电脑',
  'orialis',
  'hermes',
  'dsh',
  '总结',
  '结果',
  '回复',
  '已完成',
  '已经完成',
  '已改好',
  '已经改好了',
  '好的',
  '收到',
  '没问题',
  '当然可以',
  '继续',
}.contains(text.replaceAll(RegExp(r'[。！!：:]$'), '').trim().toLowerCase());

String? _topic(String source) {
  final text = _plain(source)
      .replaceFirst(
        RegExp(r'^(?:(?:请|麻烦你|麻烦|帮我|帮忙|能不能|能否|我想|我要|我需要|你)\s*)+'),
        '',
      )
      .split(RegExp(r'[，,。！？!?；;\n]'))
      .first
      .trim();
  return text.isEmpty || _generic(text) ? null : text;
}

String _shorten(String text, int limit) {
  if (text.characters.length <= limit) return text;
  var head = text.characters.take(limit - 1).toString().trimRight();
  final space = head.lastIndexOf(' ');
  if (space > head.length ~/ 2) head = head.substring(0, space);
  return '$head…';
}
