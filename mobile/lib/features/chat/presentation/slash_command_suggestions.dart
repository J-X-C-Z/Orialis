import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/hermes_shortcuts.dart';

class SlashCommandSuggestions extends StatelessWidget {
  const SlashCommandSuggestions({
    required this.controller,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<HermesShortcut> onSelected;
  final bool enabled;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: controller,
    builder: (context, value, _) {
      final query = value.text.trimLeft().toLowerCase();
      if (!enabled || !query.startsWith('/') || query.contains(RegExp(r'\s'))) {
        return const SizedBox.shrink();
      }
      final matches = hermesShortcuts
          .where((shortcut) => shortcut.command.toLowerCase().startsWith(query))
          .toList();
      if (matches.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Hermes 指令 · 选择后再发送',
                  style: LuminaTheme.of(context).textTheme.labelSmall,
                ),
                for (final shortcut in matches)
                  LuminaListRow(
                    title:
                        '${shortcut.command.trimRight()} · ${shortcut.title}',
                    subtitle: shortcut.description,
                    onTap: () => onSelected(shortcut),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
