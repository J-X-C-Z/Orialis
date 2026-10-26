import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

/// Suggestions only fill a draft through [onSelect]; they never send a message.
class ChatEmptySuggestions extends StatelessWidget {
  const ChatEmptySuggestions({required this.onSelect, super.key});

  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return Column(
      key: const ValueKey('chat-empty-suggestions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text('从一个想法开始', style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: 4),
        Text('选择方向，编辑后再发送', style: theme.textTheme.bodySmall),
        const SizedBox(height: LuminaSpacing.compact),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            const gap = LuminaSpacing.tight;
            final columns = constraints.maxWidth >= 420 * scale ? 2 : 1;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final (label, detail, prompt, icon) in const [
                  ('学习', '解释概念，循序练习', '请帮我理解一个知识点：', LuminaIcons.sparkles),
                  ('图表', '梳理数据与关系', '请用图表帮我分析：', LuminaIcons.branch),
                  ('计划', '把目标拆成下一步', '请帮我制定一个可执行的计划：', LuminaIcons.tasks),
                  ('资料', '整理要点与参考来源', '请帮我整理这些资料的要点：', LuminaIcons.folder),
                ])
                  SizedBox(
                    width: width,
                    child: Semantics(
                      button: true,
                      hint: '填入草稿，编辑后发送',
                      child: LuminaButton(
                        key: ValueKey('chat-suggestion-$label'),
                        primary: false,
                        onPressed: () => onSelect(prompt),
                        child: Row(
                          children: [
                            LuminaIcon(icon, color: theme.colors.accent),
                            const SizedBox(width: LuminaSpacing.tight),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label,
                                    style: theme.textTheme.labelMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    detail,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
