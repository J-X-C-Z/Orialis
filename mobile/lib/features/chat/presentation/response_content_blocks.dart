import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

class ResponseContentBlock extends StatelessWidget {
  const ResponseContentBlock({required this.data, super.key});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) => switch (data['type']) {
    'callout' => _callouts(context),
    'steps' => _steps(context),
    'comparison' => _comparison(context),
    'facts' => _facts(context),
    'code' => _code(context),
    _ => const SizedBox.shrink(),
  };

  List<Map<String, dynamic>> get _items =>
      (data['items'] as List).cast<Map<String, dynamic>>();

  Widget _callouts(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    final icons = {
      'info': Icons.info_outline,
      'success': Icons.check_circle_outline,
      'warning': Icons.warning_amber_rounded,
      'critical': Icons.error_outline,
    };
    final tones = {
      'info': colors.accent,
      'success': colors.tone(const Color(0xFF2E8B57), const Color(0xFF8FD3B0)),
      'warning': colors.tone(const Color(0xFFB7791F), const Color(0xFFE8BA6B)),
      'critical': colors.tone(const Color(0xFFB42318), const Color(0xFFFF8A80)),
    };
    final inset = _items.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Builder(
              builder: (context) {
                final tone = item['tone'] ?? 'info';
                final color = tones[tone] ?? colors.accent;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: inset ? color.withValues(alpha: .07) : null,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(inset ? 10 : 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ReliefSymbol(
                          icons[tone] ?? icons['info']!,
                          color: color,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item['label'] as String,
                                style: TextStyle(
                                  color: color,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              LuminaSelectableText(item['content'] as String),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _steps(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    return Column(
      children: [
        for (var i = 0; i < _items.length; i++)
          Builder(
            builder: (context) {
              final item = _items[i];
              final status = item['status'] ?? 'pending';
              final done = status == 'done';
              final current = status == 'current';
              final color = done || current
                  ? colors.accent
                  : colors.ink.withValues(alpha: .5);
              return Padding(
                padding: EdgeInsets.only(
                  bottom: i == _items.length - 1 ? 0 : 14,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        _ReliefSymbol(
                          done
                              ? Icons.check_circle
                              : current
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: color,
                          size: 22,
                          inset: current,
                        ),
                        if (i < _items.length - 1)
                          Container(
                            width: 2,
                            height: 22,
                            color: colors.recessedSurface,
                          ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['label'] as String,
                              style: TextStyle(
                                fontWeight: current
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: done
                                    ? colors.ink.withValues(alpha: .65)
                                    : colors.ink,
                              ),
                            ),
                            if (item['detail'] != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: LuminaSelectableText(
                                  item['detail'] as String,
                                ),
                              ),
                            const SizedBox(height: 2),
                            Text(switch (status) {
                              'done' => '已完成',
                              'current' => '进行中',
                              _ => '待处理',
                            }, style: TextStyle(color: color, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _comparison(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    final columns = (data['columns'] as List).cast<String>();
    final recommended = data['recommendedIndex'] as int?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['label'] as String,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < columns.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: Text(
                            columns[i],
                            style: TextStyle(
                              color: i == recommended
                                  ? colors.accent
                                  : colors.ink.withValues(alpha: .65),
                              fontWeight: i == recommended
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: LuminaSelectableText(
                            (item['values'] as List)[i] as String,
                          ),
                        ),
                        if (i == recommended)
                          _ReliefSymbol(
                            Icons.star,
                            size: 16,
                            color: colors.accent,
                          ),
                      ],
                    ),
                  ),
                if (item != _items.last) ...[
                  const SizedBox(height: 10),
                  Divider(height: 1, color: colors.ink.withValues(alpha: .12)),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _facts(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['label'] as String,
                  style: TextStyle(color: colors.ink.withValues(alpha: .65)),
                ),
                const SizedBox(height: 4),
                LuminaSelectableText(
                  item['value'] as String,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (item['detail'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: LuminaSelectableText(item['detail'] as String),
                  ),
                if (item != _items.last) ...[
                  const SizedBox(height: 10),
                  Divider(height: 1, color: colors.ink.withValues(alpha: .12)),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _code(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final item in _items)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: LuminaTheme.of(context).colors.recessedSurface
                  .withValues(alpha: .55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item['label'] as String,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (item['language'] != null)
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              item['language'] as String,
                              style: LuminaTheme.of(context)
                                  .textTheme
                                  .bodySmall,
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      item['source'] as String,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: LuminaButton(
                      primary: false,
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: item['source'] as String),
                        );
                        if (context.mounted) {
                          showLuminaToast(context, '源码已复制');
                        }
                      },
                      child: const Text('复制源码'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

/// Static status mark; the shared material supplies the same cached relief as cards.
class _ReliefSymbol extends StatelessWidget {
  const _ReliefSymbol(
    this.icon, {
    required this.color,
    this.size = 22,
    this.inset = false,
  });
  final IconData icon;
  final Color color;
  final double size;
  final bool inset;

  @override
  Widget build(BuildContext context) => LuminaSurface(
    depth: inset ? LuminaSurfaceDepth.recessed : LuminaSurfaceDepth.raised,
    liquidGlass: false,
    radius: (size + 10) / 2,
    padding: const EdgeInsets.all(5),
    child: Icon(icon, size: size, color: color),
  );
}
