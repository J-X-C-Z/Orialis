import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

/// Ordinary suggestions fill a draft; the schedule action starts a read-only query.
const chatSchedulePrompt =
    '请帮我快捷查看日程：先发现并使用当前可用的数据来源，'
    '读取最近7天消息中枢的消息，以及其他已接入且有权限访问的通知、笔记、记忆和已有日历内容。'
    '以当前本地日期和时区为准，整理今天及未来7天的课程、会议、活动、截止时间和待办。'
    '合并重复内容，按时间排列，标明每项的来源、时间和地点；时间不明确或冲突的事项单列为待确认。'
    '先给出今天最需要关注的安排，再展示近期日程。无法访问的来源请明确说明，不要猜测或把未读取的来源说成已读取。'
    '本次仅查看和整理，不创建、修改日程或发送消息。';

class ChatEmptySuggestions extends StatelessWidget {
  const ChatEmptySuggestions({
    required this.onSelect,
    this.onSchedule,
    super.key,
  });

  final ValueChanged<String> onSelect;
  final VoidCallback? onSchedule;

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
        Text('一键查看日程，或选择方向开始提问', style: theme.textTheme.bodySmall),
        const SizedBox(height: LuminaSpacing.compact),
        LuminaButton(
          key: const ValueKey('chat-suggestion-日程'),
          primary: false,
          onPressed: onSchedule,
          child: Row(
            children: [
              LuminaIcon(LuminaIcons.calendar, color: theme.colors.accent),
              const SizedBox(width: LuminaSpacing.tight),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('查看日程', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    Text(
                      '读取近期消息与其他来源，整理近期安排',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
