import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../../../core/database/app_database.dart';
import '../domain/chat_transcript.dart';
import 'safe_markdown.dart' show responseUiPlainText;

/// Searches the current account's locally saved conversation, including UI fallbacks.
class ChatMessageSearch extends StatefulWidget {
  const ChatMessageSearch({
    required this.messages,
    required this.onSelected,
    super.key,
  });

  final Stream<List<Message>> messages;
  final ValueChanged<String> onSelected;

  @override
  State<ChatMessageSearch> createState() => _ChatMessageSearchState();
}

class _ChatMessageSearchState extends State<ChatMessageSearch> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .65,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('搜索会话', style: LuminaTheme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          '搜索本机已同步的消息和卡片摘要',
          style: LuminaTheme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        LuminaTextField(
          key: const ValueKey('chat-message-search-input'),
          controller: _controller,
          hintText: '输入关键词…',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<List<Message>>(
            stream: widget.messages,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const LuminaEmptyState(
                  text: '消息暂时无法读取，请关闭后重试。',
                  card: false,
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: LuminaProgress());
              }
              final query = _controller.text.trim().toLowerCase();
              if (query.isEmpty) {
                return const LuminaEmptyState(
                  text: '输入关键词，找到之前的想法或回答。',
                  card: false,
                );
              }
              final matches = snapshot.data!
                  .where(isVisibleChatMessage)
                  .map(
                    (message) => (
                      message: message,
                      text: message.role == 'assistant'
                          ? responseUiPlainText(message.content)
                          : message.content,
                    ),
                  )
                  .where((item) => item.text.toLowerCase().contains(query))
                  .toList()
                  .reversed
                  .toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${matches.length} 条结果',
                    style: LuminaTheme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: matches.isEmpty
                        ? const LuminaEmptyState(
                            text: '没有匹配的消息，试试其他关键词。',
                            card: false,
                          )
                        : ListView.separated(
                            itemCount: matches.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final item = matches[index];
                              final at = item.text.toLowerCase().indexOf(query);
                              final start = at > 36 ? at - 36 : 0;
                              final excerpt =
                                  '${start > 0 ? '…' : ''}${item.text.substring(start)}';
                              return LuminaSurface(
                                onTap: () => widget.onSelected(item.message.id),
                                padding: const EdgeInsets.all(12),
                                radius: 14,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${item.message.role == 'user' ? '我' : '助手'} · ${_dateLabel(item.message.createdAt)}',
                                      style: LuminaTheme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      excerpt,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

String _dateLabel(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return '';
  return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
