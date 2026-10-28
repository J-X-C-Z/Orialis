import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:url_launcher/url_launcher.dart';

import '../domain/response_interactive_schema.dart';
import 'response_table_block.dart';

class ResponseInteractiveBlock extends StatefulWidget {
  const ResponseInteractiveBlock({
    required this.data,
    this.onPromptSelected,
    super.key,
  });

  final Map<String, dynamic> data;
  final ValueChanged<String>? onPromptSelected;

  @override
  State<ResponseInteractiveBlock> createState() =>
      _ResponseInteractiveBlockState();
}

class _ResponseInteractiveBlockState extends State<ResponseInteractiveBlock> {
  final _values = <String, Object?>{};
  final _controllers = <String, TextEditingController>{};
  final _expanded = <int>{};
  bool _submitted = false;
  bool _hasChanges = false;
  String? _notice;

  List<Map<String, dynamic>> get _items =>
      (widget.data['items'] as List).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    _values.clear();
    _expanded.clear();
    _submitted = false;
    _hasChanges = false;
    _notice = null;
    if (widget.data['type'] != 'form') return;
    for (final item in _items) {
      final id = item['id'] as String;
      final value = item['value'];
      _values[id] = switch (item['kind']) {
        'multiselect' => List<String>.from(value as List? ?? const []),
        'slider' => ((value ?? item['min']) as num).toDouble(),
        _ => value,
      };
      if (item['kind'] == 'text' || item['kind'] == 'date') {
        (_controllers[id] ??= TextEditingController()).text =
            value as String? ?? '';
      }
    }
  }

  @override
  void didUpdateWidget(ResponseInteractiveBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(oldWidget.data) != jsonEncode(widget.data)) _reset();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (widget.data['type']) {
    'form' => _form(),
    'table' => ResponseTableBlock(data: widget.data),
    'sources' => _sources(),
    'diff' => _diff(),
    'accordion' => _accordion(),
    _ => const SizedBox.shrink(),
  };

  Widget _form() {
    final theme = LuminaTheme.of(context);
    final requiredCount = _items
        .where((item) => item['required'] == true)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_items.length} 项信息 · $requiredCount 项必填',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (final item in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _field(item),
          ),
        Row(
          children: [
            Expanded(
              child: LuminaButton(
                onPressed: widget.onPromptSelected == null
                    ? null
                    : () {
                        final error = responseFormError(widget.data, _values);
                        setState(() => _submitted = true);
                        if (error == null) {
                          widget.onPromptSelected!(
                            responseFormPrompt(widget.data, _values),
                          );
                          setState(() => _notice = '已填入输入框，请确认后发送');
                        }
                      },
                child: const Text('填入输入框'),
              ),
            ),
            if (_hasChanges) ...[
              const SizedBox(width: 8),
              Expanded(
                child: LuminaButton(
                  key: const ValueKey('form-reset'),
                  primary: false,
                  onPressed: () {
                    FocusScope.of(context).unfocus();
                    setState(_reset);
                  },
                  child: const Text('重置表单'),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _notice ?? '填写内容仅保留在当前视图；填入后由你确认发送。',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _field(Map<String, dynamic> item) {
    final theme = LuminaTheme.of(context);
    final id = item['id'] as String;
    final error = _submitted ? responseFormFieldError(item, _values[id]) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(item['label'] as String, style: theme.textTheme.labelMedium),
            Text(
              item['required'] == true ? '必填' : '选填',
              style: theme.textTheme.bodySmall.copyWith(
                color: item['required'] == true
                    ? theme.colors.accent
                    : theme.colors.muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Semantics(
          label: '${item['label']}${item['required'] == true ? '，必填' : ''}',
          child: _fieldControl(item),
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              key: ValueKey('form-error-$id'),
              style: theme.textTheme.bodySmall.copyWith(
                color: theme.colors.danger,
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _changeValue(String id, Object? value) => setState(() {
    _values[id] = value;
    _hasChanges = true;
    _notice = null;
  });

  Widget _fieldControl(Map<String, dynamic> item) {
    final id = item['id'] as String;
    switch (item['kind']) {
      case 'text':
      case 'date':
        final field = LuminaTextField(
          key: ValueKey('field-$id'),
          controller: _controllers[id]!,
          hint: item['kind'] == 'date' ? 'YYYY-MM-DD' : '请输入',
          maxLength: item['kind'] == 'date' ? 10 : 1000,
          keyboardType: item['kind'] == 'date'
              ? TextInputType.datetime
              : TextInputType.text,
          onChanged: (value) => _changeValue(id, value),
        );
        if (item['kind'] == 'text') return field;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: LuminaButton(
                primary: false,
                onPressed: () async {
                  final controller = _controllers[id]!;
                  final current = _values[id] as String?;
                  final selected = await showDatePicker(
                    context: context,
                    initialDate: current != null && responseDateIsValid(current)
                        ? DateTime.parse(current)
                        : DateTime.now(),
                    firstDate: DateTime(1),
                    lastDate: DateTime(9999, 12, 31),
                  );
                  if (!mounted ||
                      selected == null ||
                      _controllers[id] != controller) {
                    return;
                  }
                  final value = selected.toIso8601String().substring(0, 10);
                  controller.text = value;
                  _changeValue(id, value);
                },
                child: const Text('选择日期'),
              ),
            ),
          ],
        );
      case 'select':
      case 'multiselect':
        final multiple = item['kind'] == 'multiselect';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in item['options'] as List)
                  Semantics(
                    selected: multiple
                        ? (_values[id] as List).contains(option)
                        : _values[id] == option,
                    button: true,
                    child: LuminaButton(
                      primary: multiple
                          ? (_values[id] as List).contains(option)
                          : _values[id] == option,
                      onPressed: () => setState(() {
                        _notice = null;
                        _hasChanges = true;
                        if (multiple) {
                          final selected = _values[id] as List<String>;
                          selected.contains(option)
                              ? selected.remove(option)
                              : selected.add(option);
                        } else {
                          _values[id] = option;
                        }
                      }),
                      child: Text(option as String),
                    ),
                  ),
              ],
            ),
          ],
        );
      case 'slider':
        final value = _values[id] as double;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '当前值：${value.toStringAsFixed(2)}',
              style: LuminaTheme.of(context).textTheme.bodySmall,
            ),
            Slider(
              key: ValueKey('slider-$id'),
              value: value,
              min: (item['min'] as num).toDouble(),
              max: (item['max'] as num).toDouble(),
              label: value.toStringAsFixed(2),
              onChanged: (value) => _changeValue(id, value),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _openSource(String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) setState(() => _notice = '链接未能打开，可复制来源地址');
    } catch (_) {
      if (mounted) setState(() => _notice = '链接未能打开，可复制来源地址');
    }
  }

  Widget _panel(Widget child) => LuminaSurface(
    radius: 16,
    padding: const EdgeInsets.all(12),
    child: child,
  );

  void _toggle(int index) => setState(() {
    _expanded.contains(index) ? _expanded.remove(index) : _expanded.add(index);
  });

  Widget _accordion() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < _items.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  expanded: _expanded.contains(i),
                  child: LuminaButton(
                    key: ValueKey('accordion-toggle-$i'),
                    primary: false,
                    icon: Icon(
                      _expanded.contains(i)
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: LuminaTheme.of(context).colors.accent,
                    ),
                    onPressed: () => _toggle(i),
                    child: Text(_items[i]['label'] as String),
                  ),
                ),
                if (_expanded.contains(i)) ...[
                  const SizedBox(height: 12),
                  LuminaSelectableText(
                    _items[i]['content'] as String,
                    key: ValueKey('accordion-content-$i'),
                    style: LuminaTheme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
        ),
    ],
  );

  Widget _sources() {
    final theme = LuminaTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${_items.length} 个来源', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        for (var i = 0; i < _items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${i + 1}. ${_items[i]['label']}',
                    style: theme.textTheme.recessedTitle,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Uri.parse(_items[i]['url'] as String).host,
                    style: theme.textTheme.labelMedium.copyWith(
                      color: theme.colors.accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: LuminaButton(
                          primary: false,
                          onPressed: () =>
                              _openSource(_items[i]['url'] as String),
                          child: const Text('打开来源'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LuminaButton(
                          primary: false,
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: _items[i]['url'] as String),
                          ),
                          child: const Text('复制地址'),
                        ),
                      ),
                    ],
                  ),
                  if (_items[i]['excerpt'] != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: LuminaButton(
                        primary: false,
                        onPressed: () => _toggle(i),
                        child: Text(_expanded.contains(i) ? '收起摘录' : '查看摘录'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  if (_items[i]['sourceId'] != null)
                    Text(
                      '来源编号：${_items[i]['sourceId']}',
                      style: theme.textTheme.bodySmall,
                    ),
                  LuminaSelectableText(
                    _items[i]['url'] as String,
                    style: theme.textTheme.bodySmall,
                  ),
                  if (_expanded.contains(i)) ...[
                    const SizedBox(height: 12),
                    Text('摘录', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 6),
                    LuminaSelectableText(_items[i]['excerpt'] as String),
                  ],
                ],
              ),
            ),
          ),
        if (_notice != null) Text(_notice!, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _diff() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < _items.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _diffCard(i),
        ),
      if (_notice != null)
        Text(_notice!, style: LuminaTheme.of(context).textTheme.bodySmall),
    ],
  );

  Widget _diffCard(int index) {
    final theme = LuminaTheme.of(context);
    final item = _items[index];
    final lines = _diffRows(item);
    final added = lines.where((line) => line.$1 == '+').length;
    final removed = lines.where((line) => line.$1 == '−').length;
    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(item['label'] as String, style: theme.textTheme.recessedTitle),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                '新增 $added 行',
                style: theme.textTheme.bodySmall.copyWith(
                  color: theme.colors.accent,
                ),
              ),
              Text(
                '移除 $removed 行',
                style: theme.textTheme.bodySmall.copyWith(
                  color: theme.colors.danger,
                ),
              ),
              if (added == 0 && removed == 0)
                Text('无变更', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              LuminaButton(
                primary: false,
                onPressed: () => _toggle(index),
                child: Text(_expanded.contains(index) ? '收起对比' : '展开对比'),
              ),
              LuminaButton(
                primary: false,
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: item['after'] as String),
                  );
                  if (mounted) setState(() => _notice = '修改后的内容已复制');
                },
                child: const Text('复制修改后内容'),
              ),
            ],
          ),
          if (_expanded.contains(index)) ...[
            const SizedBox(height: 12),
            Text('− 修改前 / + 修改后', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            _diffLines(lines),
          ],
        ],
      ),
    );
  }

  List<(String, String)> _diffRows(Map<String, dynamic> item) {
    final oldText = item['before'] as String;
    final newText = item['after'] as String;
    final before = oldText.isEmpty ? <String>[] : oldText.split('\n');
    final after = newText.isEmpty ? <String>[] : newText.split('\n');
    var prefix = 0, suffix = 0;
    while (prefix < before.length &&
        prefix < after.length &&
        before[prefix] == after[prefix]) {
      prefix++;
    }
    while (suffix < before.length - prefix &&
        suffix < after.length - prefix &&
        before[before.length - suffix - 1] ==
            after[after.length - suffix - 1]) {
      suffix++;
    }
    return <(String, String)>[
      for (final line in before.take(prefix)) (' ', line),
      for (final line
          in before.skip(prefix).take(before.length - prefix - suffix))
        ('−', line),
      for (final line
          in after.skip(prefix).take(after.length - prefix - suffix))
        ('+', line),
      for (final line in after.skip(after.length - suffix)) (' ', line),
    ];
  }

  Widget _diffLines(List<(String, String)> lines) {
    final colors = LuminaTheme.of(context).colors;
    return SizedBox(
      height: 320,
      child: ListView.builder(
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final (marker, line) = lines[index];
          return ColoredBox(
            color: marker == '+'
                ? colors.accent.withValues(alpha: .12)
                : marker == '−'
                ? colors.danger.withValues(alpha: .12)
                : Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
              child: LuminaSelectableText(
                '$marker $line',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: colors.ink,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
