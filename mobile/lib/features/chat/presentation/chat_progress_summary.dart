import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import 'safe_markdown.dart';
import '../../../app/design/chat_symbols.dart';

class ChatProgressSummary extends StatefulWidget {
  const ChatProgressSummary({
    required this.content,
    required this.completed,
    super.key,
  });

  final String content;
  final bool completed;

  @override
  State<ChatProgressSummary> createState() => _ChatProgressSummaryState();
}

class _ChatProgressSummaryState extends State<ChatProgressSummary> {
  late bool _expanded = !widget.completed;

  @override
  void didUpdateWidget(ChatProgressSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.completed && widget.completed) _expanded = false;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: LuminaSurface(
      radius: 16,
      liquidGlass: false,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: LuminaButton(
              primary: false,
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const ChatSymbol(
                      ChatSymbolKind.summary,
                      size: 20,
                      animated: false,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '处理摘要',
                        style: LuminaTheme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    LuminaIcon(
                      _expanded
                          ? LuminaIcons.chevronDown
                          : LuminaIcons.chevronRight,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            SafeMarkdownView(source: widget.content, allowResponseUi: false),
        ],
      ),
    ),
  );
}
