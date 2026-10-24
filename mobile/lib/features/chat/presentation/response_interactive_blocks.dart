import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:url_launcher/url_launcher.dart';

import '../domain/response_interactive_schema.dart';

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
  final _search = TextEditingController();
  final _expanded = <int>{};
  int? _sortColumn;
  bool _ascending = true, _saving = false;
  String? _error, _notice;

  List<Map<String, dynamic>> get _items =>
      (widget.data['items'] as List).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _values.clear();
    _expanded.clear();
    _search.clear();
    _sortColumn = null;
    _ascending = true;
    _error = _notice = null;
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
        _controllers[id] = TextEditingController(text: value as String? ?? '');
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
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (widget.data['type']) {
    'form' => _form(),
    'table' => _table(),
    'sources' => _sources(),
    'diff' => _diff(),
    _ => const SizedBox.shrink(),
  };

  Widget _form() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final item in _items)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _field(item),
        ),
      if (_error != null)
        Text(_error!, style: const TextStyle(color: Colors.red)),
      LuminaButton(
        onPressed: widget.onPromptSelected == null
            ? null
            : () {
                final error = responseFormError(widget.data, _values);
                setState(() => _error = error);
                if (error == null) {
                  widget.onPromptSelected!(
                    responseFormPrompt(widget.data, _values),
                  );
                  setState(() => _notice = '已填入输入框，请确认后发送');
                }
              },
        child: const Text('填入输入框'),
      ),
      const SizedBox(height: 6),
      Text(
        _notice ?? '填写内容仅保留在当前视图；填入后由你确认发送。',
        style: LuminaTheme.of(context).textTheme.bodySmall,
      ),
    ],
  );

  Widget _field(Map<String, dynamic> item) {
    final id = item['id'] as String;
    final label = '${item['label']}${item['required'] == true ? ' *' : ''}';
    switch (item['kind']) {
      case 'text':
      case 'date':
        final field = LuminaTextField(
          key: ValueKey('field-$id'),
          controller: _controllers[id]!,
          label: label,
          hint: item['kind'] == 'date' ? 'YYYY-MM-DD' : '请输入',
          maxLength: item['kind'] == 'date' ? 10 : 1000,
          keyboardType: item['kind'] == 'date'
              ? TextInputType.datetime
              : TextInputType.text,
          onChanged: (value) => _values[id] = value,
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
                  _values[id] = value;
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
            Text(label, style: LuminaTheme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
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
            Text('$label：${value.toStringAsFixed(2)}'),
            Slider(
              key: ValueKey('slider-$id'),
              value: value,
              min: (item['min'] as num).toDouble(),
              max: (item['max'] as num).toDouble(),
              label: value.toStringAsFixed(2),
              onChanged: (value) => setState(() => _values[id] = value),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  List<Map<String, dynamic>> _visibleRows() {
    final query = _search.text.trim().toLowerCase();
    final rows = _items
        .where(
          (row) => '${row['label']} ${(row['cells'] as List).join(' ')}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    final column = _sortColumn;
    if (column != null) {
      rows.sort((a, b) {
        final left = (a['cells'] as List)[column];
        final right = (b['cells'] as List)[column];
        final comparison = left is num && right is num
            ? left.compareTo(right)
            : '$left'.compareTo('$right');
        return _ascending ? comparison : -comparison;
      });
    }
    return rows;
  }

  String _csv() => responseTableCsv(
    (widget.data['columns'] as List).cast<String>(),
    _visibleRows()
        .map((row) => (row['cells'] as List).cast<Object?>())
        .toList(),
  );

  Future<void> _saveCsv() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final path = await FilePicker.saveFile(
        fileName: 'orialis-table.csv',
        mimeType: 'text/csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
        bytes: Uint8List.fromList(utf8.encode('\uFEFF${_csv()}')),
      );
      if (mounted && path != null) setState(() => _notice = '表格已导出');
    } catch (_) {
      if (mounted) setState(() => _notice = '导出失败，请重试或复制 CSV');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _table() {
    final columns = (widget.data['columns'] as List).cast<String>();
    final rows = _visibleRows();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LuminaTextField(
          controller: _search,
          label: '筛选表格',
          hint: '搜索任意单元格',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(
          '显示 ${rows.length} / ${_items.length} 行；点击列名排序',
          style: LuminaTheme.of(context).textTheme.bodySmall,
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            sortColumnIndex: _sortColumn == null ? null : _sortColumn! + 1,
            sortAscending: _ascending,
            dataRowMinHeight: 48,
            dataRowMaxHeight: double.infinity,
            columns: [
              const DataColumn(label: Text('详情')),
              for (var i = 0; i < columns.length; i++)
                DataColumn(
                  label: Text(columns[i]),
                  onSort: (column, ascending) => setState(() {
                    _sortColumn = i;
                    _ascending = ascending;
                  }),
                ),
            ],
            rows: [
              for (final row in rows)
                DataRow(
                  cells: [
                    DataCell(
                      Semantics(
                        label: '${row['label']} 展开行',
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: LuminaTheme.of(context)
                                .colors
                                .accent,
                            textStyle: LuminaTheme.of(context)
                                .textTheme
                                .labelMedium,
                          ),
                          onPressed: () => _showRow(columns, row),
                          child: const Text('展开行'),
                        ),
                      ),
                    ),
                    for (final cell in row['cells'] as List)
                      DataCell(
                        SizedBox(
                          width: 180,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '$cell',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LuminaButton(
              primary: false,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _csv()));
                if (mounted) setState(() => _notice = 'CSV 已复制');
              },
              child: const Text('复制 CSV'),
            ),
            LuminaButton(
              primary: false,
              onPressed: _saving ? null : _saveCsv,
              child: Text(_saving ? '正在导出…' : '导出 CSV'),
            ),
          ],
        ),
        if (_notice != null) Text(_notice!),
      ],
    );
  }

  Future<void> _showRow(List<String> columns, Map<String, dynamic> row) {
    final theme = LuminaTheme.of(context);
    final media = MediaQuery.of(context);
    return showDialog<void>(
      context: context,
      builder: (context) => MediaQuery(
        data: media,
        child: LuminaTheme(
          data: theme.data,
          brightness: theme.brightness,
          tint: theme.tint,
          darkProgress: theme.darkProgress,
          highPerformanceMode: theme.highPerformanceMode,
          reduceTransparency: theme.reduceTransparency,
          child: AlertDialog(
            insetPadding: const EdgeInsets.all(16),
            scrollable: true,
            title: Text(row['label'] as String),
            content: SizedBox(
              width: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < columns.length; i++) ...[
                    Text(
                      columns[i],
                      style: LuminaTheme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    LuminaSelectableText('${(row['cells'] as List)[i]}'),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭详情'),
              ),
            ],
          ),
        ),
      ),
    );
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

  Widget _sources() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < _items.length; i++) ...[
        Text(
          '${i + 1}. ${_items[i]['label']}',
          style: LuminaTheme.of(context).textTheme.recessedTitle,
        ),
        if (_items[i]['sourceId'] != null)
          Text('来源编号：${_items[i]['sourceId']}'),
        LuminaSelectableText(_items[i]['url'] as String),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LuminaButton(
              primary: false,
              onPressed: () => _openSource(_items[i]['url'] as String),
              child: const Text('打开来源'),
            ),
            LuminaButton(
              primary: false,
              onPressed: () => Clipboard.setData(
                ClipboardData(text: _items[i]['url'] as String),
              ),
              child: const Text('复制地址'),
            ),
            if (_items[i]['excerpt'] != null)
              LuminaButton(
                primary: false,
                onPressed: () => setState(() {
                  _expanded.contains(i)
                      ? _expanded.remove(i)
                      : _expanded.add(i);
                }),
                child: Text(_expanded.contains(i) ? '收起摘录' : '查看摘录'),
              ),
          ],
        ),
        if (_expanded.contains(i)) ...[
          const SizedBox(height: 8),
          LuminaSelectableText(_items[i]['excerpt'] as String),
        ],
        const SizedBox(height: 16),
      ],
      if (_notice != null) Text(_notice!),
    ],
  );

  Widget _diff() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < _items.length; i++) ...[
        Text(
          _items[i]['label'] as String,
          style: LuminaTheme.of(context).textTheme.recessedTitle,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LuminaButton(
              primary: false,
              onPressed: () => setState(() {
                _expanded.contains(i) ? _expanded.remove(i) : _expanded.add(i);
              }),
              child: Text(_expanded.contains(i) ? '收起对比' : '展开对比'),
            ),
            LuminaButton(
              primary: false,
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: _items[i]['after'] as String),
                );
                if (mounted) setState(() => _notice = '修改后的内容已复制');
              },
              child: const Text('复制修改后内容'),
            ),
          ],
        ),
        if (_expanded.contains(i)) _diffLines(_items[i]),
        const SizedBox(height: 12),
      ],
      if (_notice != null) Text(_notice!),
    ],
  );

  Widget _diffLines(Map<String, dynamic> item) {
    final before = (item['before'] as String).split('\n');
    final after = (item['after'] as String).split('\n');
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
    final lines = <(String, String)>[
      for (final line in before.take(prefix)) (' ', line),
      for (final line
          in before.skip(prefix).take(before.length - prefix - suffix))
        ('−', line),
      for (final line
          in after.skip(prefix).take(after.length - prefix - suffix))
        ('+', line),
      for (final line in after.skip(after.length - suffix)) (' ', line),
    ];
    return SizedBox(
      height: 320,
      child: ListView.builder(
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final (marker, line) = lines[index];
          return ColoredBox(
            color: marker == '+'
                ? Colors.green.withValues(alpha: .1)
                : marker == '−'
                ? Colors.red.withValues(alpha: .1)
                : Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
              child: LuminaSelectableText(
                '$marker $line',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          );
        },
      ),
    );
  }
}
