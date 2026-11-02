import 'package:lumina_ui/lumina_ui.dart';

enum ItemCategory {
  course('course', '课程', LuminaCardPalette.ocean),
  transit('transit', '交通', LuminaCardPalette.amber),
  leisure('leisure', '玩乐', LuminaCardPalette.lavender),
  work('work', '工作', LuminaCardPalette.sage),
  health('health', '健康', LuminaCardPalette.rose),
  life('life', '生活', LuminaCardPalette.mist),
  general('general', '其他', null);

  const ItemCategory(this.value, this.label, this.palette);
  final String value;
  final String label;
  final LuminaCardPalette? palette;

  static ItemCategory resolve(String value) =>
      values.where((category) => category.value == value).firstOrNull ??
      general;

  LuminaColors colors(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return LuminaColors(
      tint: palette?.tint,
      darkProgress: theme.colors.darkProgress,
      neumorphic: theme.data.neumorphic,
    );
  }
}

class CategoryBadge extends StatelessWidget {
  const CategoryBadge({required this.value, super.key});
  final String value;

  @override
  Widget build(BuildContext context) {
    final category = ItemCategory.resolve(value);
    final colors = category.colors(context);
    return Semantics(
      label: '分类：${category.label}',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: category == ItemCategory.general
                ? colors.surface
                : colors.accentSoft,
            borderRadius: BorderRadius.circular(LuminaRadius.attachment),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 5,
                  height: 12,
                  decoration: BoxDecoration(
                    color: category == ItemCategory.general
                        ? colors.muted
                        : colors.accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  category.label,
                  style: LuminaTheme.of(context).textTheme.labelSmall
                      .copyWith(color: colors.ink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CategoryField extends StatelessWidget {
  const CategoryField({
    required this.value,
    required this.onChanged,
    super.key,
  });
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => LuminaListRow(
    title: '分类',
    trailing: CategoryBadge(value: value),
    onTap: () async {
      final selected = await showLuminaSheet<String>(
        context: context,
        builder: (sheetContext) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '选择分类',
                style: LuminaTheme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              for (final category in ItemCategory.values)
                LuminaListRow(
                  title: category.label,
                  leading: DecoratedBox(
                    decoration: BoxDecoration(
                      color: category == ItemCategory.general
                          ? category.colors(sheetContext).muted
                          : category.colors(sheetContext).accent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const SizedBox(width: 12, height: 20),
                  ),
                  trailing: category.value == value
                      ? const LuminaIcon(LuminaIcons.check)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(category.value),
                ),
            ],
          ),
        ),
      );
      if (selected != null && context.mounted) onChanged(selected);
    },
  );
}
