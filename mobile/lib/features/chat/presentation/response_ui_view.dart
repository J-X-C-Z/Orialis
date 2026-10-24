import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/response_ui.dart';
import 'response_svg_view.dart';
import '../domain/response_visual_schema.dart';
import '../domain/response_interactive_schema.dart';
import '../domain/response_action_schema.dart';
import 'response_visual_blocks.dart';
import 'response_interactive_blocks.dart';
import 'response_action_blocks.dart';

class ResponseUiView extends StatefulWidget {
  const ResponseUiView({
    required this.document,
    this.onPromptSelected,
    this.actionScope,
    super.key,
  });
  final ResponseUiDocument document;
  final ValueChanged<String>? onPromptSelected;
  final String? actionScope;

  @override
  State<ResponseUiView> createState() => _ResponseUiViewState();
}

class _ResponseUiViewState extends State<ResponseUiView> {
  final _tabs = <int, int>{};
  // shortcut: checklist edits live in this view; sync only if cross-device editing is added.
  final _checks = <(int, int), bool>{};

  @override
  void didUpdateWidget(ResponseUiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _tabs.removeWhere(
      (index, selected) =>
          index >= widget.document.blocks.length ||
          widget.document.blocks[index].type != 'tabs' ||
          selected >= widget.document.blocks[index].items.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    if (!document.supported) return LuminaSelectableText(document.fallback);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LuminaTheme.of(context).colors.surface,
        border: Border.all(color: LuminaTheme.of(context).colors.outline),
        borderRadius: BorderRadius.circular(LuminaRadius.attachment),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (document.title != null)
              Semantics(
                header: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    document.title!,
                    style: LuminaTheme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
            for (var index = 0; index < document.blocks.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: _block(context, document.blocks[index], index),
              ),
          ],
        ),
      ),
    );
  }

  Widget _block(BuildContext context, ResponseUiBlock block, int index) {
    final Widget content;
    if (visualResponseTypes.contains(block.type)) {
      content = ResponseVisualBlock(data: block.data);
    } else if (interactiveResponseTypes.contains(block.type)) {
      content = ResponseInteractiveBlock(
        data: block.data,
        onPromptSelected: widget.onPromptSelected,
      );
    } else if (actionResponseTypes.contains(block.type)) {
      content = ResponseActionBlock(
        data: block.data,
        enabled: widget.onPromptSelected != null && widget.actionScope != null,
        scope: widget.actionScope ?? 'preview',
      );
    } else {
      content = switch (block.type) {
        'metrics' => _metrics(context, block),
        'chart' => _chart(context, block),
        'svg' => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in block.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ResponseSvgView(item: item),
              ),
          ],
        ),
        'tabs' => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var item = 0; item < block.items.length; item++)
                  Semantics(
                    button: true,
                    selected: (_tabs[index] ?? 0) == item,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          LuminaControlSize.capsuleRadius,
                        ),
                        border: Border.all(
                          color: (_tabs[index] ?? 0) == item
                              ? LuminaTheme.of(context).colors.accent
                              : LuminaTheme.of(context).colors.outline,
                        ),
                      ),
                      child: LuminaButton(
                        primary: (_tabs[index] ?? 0) == item,
                        onPressed: () => setState(() => _tabs[index] = item),
                        child: Text(
                          block.items[item].label,
                          style: TextStyle(
                            fontWeight: (_tabs[index] ?? 0) == item
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            LuminaSelectableText(block.items[_tabs[index] ?? 0].content!),
          ],
        ),
        'checklist' => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var item = 0; item < block.items.length; item++)
              MergeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LuminaCheck(
                      value:
                          _checks[(index, item)] ?? block.items[item].checked,
                      onChanged: (value) =>
                          setState(() => _checks[(index, item)] = value),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(block.items[item].label),
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              '勾选仅保留在当前视图',
              style: LuminaTheme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
        'choices' => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in block.items)
              Semantics(
                button: true,
                hint: '填入输入框，确认后发送',
                child: LuminaButton(
                  primary: false,
                  onPressed: widget.onPromptSelected == null
                      ? null
                      : () => widget.onPromptSelected!(item.prompt!),
                  child: Text(item.label),
                ),
              ),
          ],
        ),
        _ => const SizedBox.shrink(),
      };
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (block.title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              block.title!,
              style: LuminaTheme.of(context).textTheme.recessedTitle,
            ),
          ),
        content,
      ],
    );
  }

  Widget _metrics(BuildContext context, ResponseUiBlock block) {
    final theme = LuminaTheme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0;
        final minimum = 132 * math.max(1, textScale) * theme.data.fontScale;
        final columns = math.max(
          1,
          math.min(
            block.items.length,
            ((constraints.maxWidth + gap) / (minimum + gap)).floor(),
          ),
        );
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in block.items)
              SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    LuminaSelectableText(
                      '${item.value}',
                      style: theme.textTheme.titleLarge,
                    ),
                    if (item.detail != null) ...[
                      const SizedBox(height: 4),
                      Text(item.detail!, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _chart(BuildContext context, ResponseUiBlock block) {
    final maximum = block.items.fold<double>(
      0,
      (value, item) => math.max(value, (item.value as num).abs().toDouble()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in block.items)
          Semantics(
            label: '${item.label}: ${item.value}${block.unit ?? ''}',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${item.label}  ${item.value}${block.unit ?? ''}'),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        height: 8,
                        child: ColoredBox(
                          color: LuminaTheme.of(context).colors.recessedSurface,
                          child: Align(
                            alignment: (item.value as num) < 0
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: FractionallySizedBox(
                              heightFactor: 1,
                              widthFactor: maximum == 0
                                  ? 0
                                  : (item.value as num).abs().toDouble() /
                                        maximum,
                              child: ColoredBox(
                                color: LuminaTheme.of(context).colors.accent,
                              ),
                            ),
                          ),
                        ),
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
}
