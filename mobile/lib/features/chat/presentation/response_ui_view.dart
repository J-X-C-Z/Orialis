import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    _checks.removeWhere((position, _) {
      final (block, item) = position;
      final blocks = widget.document.blocks;
      if (block >= blocks.length ||
          blocks[block].type != 'checklist' ||
          item >= blocks[block].items.length) {
        return true;
      }
      final before = oldWidget.document.blocks[block].items[item];
      final after = blocks[block].items[item];
      return before.label != after.label || before.checked != after.checked;
    });
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    if (!document.supported) return LuminaSelectableText(document.fallback);
    final summaryAction = Tooltip(
      message: '复制全文摘要',
      excludeFromSemantics: true,
      child: LuminaIconButton(
        key: const ValueKey('response-copy-summary'),
        tooltip: '复制全文摘要',
        icon: const LuminaIcon(LuminaIcons.file),
        onPressed: () async {
          await Clipboard.setData(
            ClipboardData(
              text: [
                if (document.title != null) document.title!,
                document.fallback,
              ].join('\n\n'),
            ),
          );
          if (context.mounted) showLuminaToast(context, '摘要已复制');
        },
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LuminaSurface(
        radius: LuminaRadius.attachment,
        padding: const EdgeInsets.all(LuminaSpacing.compact),
        liquidGlass: false,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (LuminaGlassTitleScope.of(context))
                LuminaCardHeader(
                  title: document.title ?? '智能回复',
                  trailing: summaryAction,
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            document.title ?? '智能回复',
                            style: LuminaTheme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ),
                    ),
                    summaryAction,
                  ],
                ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final split =
                      constraints.maxWidth >= 820 &&
                      MediaQuery.textScalerOf(context).scale(14) <= 21;
                  return Wrap(
                    spacing: 20,
                    runSpacing: LuminaSpacing.item,
                    children: [
                      for (
                        var index = 0;
                        index < document.blocks.length;
                        index++
                      )
                        SizedBox(
                          key: ValueKey('response-block-slot-$index'),
                          width:
                              split &&
                                  !const {
                                    'metrics',
                                    'table',
                                    'diagram',
                                    'svg',
                                    'diff',
                                    'media',
                                    'actions',
                                  }.contains(document.blocks[index].type)
                              ? (constraints.maxWidth - 20) / 2
                              : constraints.maxWidth,
                          child: Padding(
                            padding: const EdgeInsets.only(
                              top: LuminaSpacing.item,
                            ),
                            child: _block(
                              context,
                              document.blocks[index],
                              index,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
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
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: LuminaTheme.of(context).colors.recessedSurface,
                borderRadius: BorderRadius.circular(LuminaRadius.control),
              ),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
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
            ),
            const SizedBox(height: 10),
            Semantics(
              container: true,
              label: block.items[_tabs[index] ?? 0].label,
              child: LuminaSelectableText(
                block.items[_tabs[index] ?? 0].content!,
              ),
            ),
          ],
        ),
        'checklist' => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _checklistProgress(context, block, index),
            const SizedBox(height: LuminaSpacing.tight),
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
                      child: GestureDetector(
                        onTap: () => setState(
                          () => _checks[(index, item)] =
                              !(_checks[(index, item)] ??
                                  block.items[item].checked),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(block.items[item].label),
                        ),
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
        'choices' => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in block.items)
              Padding(
                padding: const EdgeInsets.only(bottom: LuminaSpacing.tight),
                child: Semantics(
                  button: true,
                  hint: '填入输入框，确认后发送',
                  child: LuminaButton(
                    primary: false,
                    onPressed: widget.onPromptSelected == null
                        ? null
                        : () => widget.onPromptSelected!(item.prompt!),
                    child: Row(
                      children: [
                        Expanded(child: Text(item.label)),
                        const SizedBox(width: 8),
                        const LuminaIcon(LuminaIcons.arrowRight, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        _ => const SizedBox.shrink(),
      };
    }
    return Container(
      key: ValueKey('response-block-$index'),
      padding: const EdgeInsets.all(LuminaSpacing.compact),
      decoration: BoxDecoration(
        border: Border.all(color: LuminaTheme.of(context).colors.outline),
        borderRadius: BorderRadius.circular(LuminaRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: LuminaSpacing.compact),
            child: LuminaGlassTitleScope.of(context)
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (block.title != null) ...[
                        Text(
                          _typeLabel(block.type),
                          style: LuminaTheme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 4),
                      ],
                      LuminaCardHeader(
                        title: block.title ?? _typeLabel(block.type),
                      ),
                    ],
                  )
                : Semantics(
                    header: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (block.title != null) ...[
                          Text(
                            _typeLabel(block.type),
                            style: LuminaTheme.of(context).textTheme.labelSmall,
                          ),
                          const SizedBox(height: 4),
                        ],
                        Text(
                          block.title ?? _typeLabel(block.type),
                          style: LuminaTheme.of(context)
                              .textTheme
                              .recessedTitle,
                        ),
                      ],
                    ),
                  ),
          ),
          content,
        ],
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
    'metrics' => '关键指标',
    'chart' => '数据对比',
    'tabs' => '分段阅读',
    'checklist' => '行动清单',
    'choices' => '继续探索',
    'svg' => '图解',
    'diagram' => '关系图',
    'math' => '公式',
    'plot' => '数据图表',
    'timeline' => '时间线',
    'simulation' => '交互演示',
    'progress' => '目标进度',
    'heatmap' => '热力图',
    'accordion' => '展开阅读',
    'form' => '信息填写',
    'table' => '数据表格',
    'sources' => '参考资料',
    'diff' => '内容对比',
    'media' => '媒体附件',
    'actions' => '待确认操作',
    _ => '内容',
  };

  Widget _checklistProgress(
    BuildContext context,
    ResponseUiBlock block,
    int index,
  ) {
    final completed = [
      for (var item = 0; item < block.items.length; item++)
        if (_checks[(index, item)] ?? block.items[item].checked) item,
    ].length;
    final label = '已完成 $completed / ${block.items.length}';
    return Semantics(
      label: '清单进度',
      value: label,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: LuminaTheme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(LuminaRadius.control),
              child: LinearProgressIndicator(
                key: ValueKey('response-checklist-progress-$index'),
                value: block.items.isEmpty ? 0 : completed / block.items.length,
                minHeight: 4,
                color: LuminaTheme.of(context).colors.accent,
                backgroundColor: LuminaTheme.of(context).colors.recessedSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metrics(BuildContext context, ResponseUiBlock block) {
    final theme = LuminaTheme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = LuminaSpacing.tight;
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
                child: Container(
                  padding: const EdgeInsets.all(LuminaSpacing.compact),
                  decoration: BoxDecoration(
                    color: theme.colors.recessedSurface,
                    borderRadius: BorderRadius.circular(LuminaRadius.control),
                  ),
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
