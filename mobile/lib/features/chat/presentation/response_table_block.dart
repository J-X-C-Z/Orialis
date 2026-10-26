import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/response_interactive_schema.dart';

class ResponseTableBlock extends StatefulWidget {
  const ResponseTableBlock({required this.data, super.key});
  final Map<String, dynamic> data;

  @override
  State<ResponseTableBlock> createState() => _ResponseTableBlockState();
}

class _ResponseTableBlockState extends State<ResponseTableBlock> {
  final _search = TextEditingController();
  int? _sortColumn;
  bool _ascending = true, _saving = false;
  int _page = 0, _pageSize = 5;
  String? _notice;

  List<Map<String, dynamic>> get _items =>
      (widget.data['items'] as List).cast<Map<String, dynamic>>();

  @override
  void didUpdateWidget(ResponseTableBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(oldWidget.data) != jsonEncode(widget.data)) {
      _search.clear();
      _sortColumn = null;
      _ascending = true;
      _page = 0;
      _pageSize = 5;
      _notice = null;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() => setState(() {
    _search.clear();
    _page = 0;
    _notice = null;
  });

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
        if (comparison == 0) {
          return _items.indexOf(a).compareTo(_items.indexOf(b));
        }
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

  @override
  Widget build(BuildContext context) {
    final columns = (widget.data['columns'] as List).cast<String>();
    final rows = _visibleRows();
    final pageCount = _pageSize == 0 || rows.isEmpty
        ? 1
        : (rows.length / _pageSize).ceil();
    final pageRows = _pageSize == 0
        ? rows
        : rows.skip(_page * _pageSize).take(_pageSize).toList();
    final theme = LuminaTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LuminaTextField(
          key: const ValueKey('table-search'),
          controller: _search,
          label: '筛选表格',
          hint: '搜索任意单元格',
          onChanged: (_) => setState(() {
            _page = 0;
            _notice = null;
          }),
        ),
        const SizedBox(height: 8),
        Text(
          '显示 ${rows.length} / ${_items.length} 行；点击列名排序',
          style: LuminaTheme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            LuminaButton(
              key: const ValueKey('table-clear-search'),
              primary: false,
              onPressed: _search.text.isEmpty ? null : _clearSearch,
              child: const Text('清除搜索'),
            ),
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
        const SizedBox(height: 8),
        Text(
          _sortColumn == null
              ? '排序：原始顺序'
              : '排序：${columns[_sortColumn!]} · ${_ascending ? '升序 ↑' : '降序 ↓'}',
          key: const ValueKey('table-sort-status'),
          style: theme.textTheme.bodySmall,
        ),
        if (_sortColumn != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: LuminaButton(
              key: const ValueKey('table-clear-sort'),
              primary: false,
              onPressed: () => setState(() {
                _sortColumn = null;
                _ascending = true;
                _page = 0;
              }),
              child: const Text('恢复原始顺序'),
            ),
          ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Padding(
            key: const ValueKey('table-empty'),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('没有匹配结果', style: theme.textTheme.recessedTitle),
                const SizedBox(height: 6),
                Text('试试其他关键词，或清除搜索恢复全部行。', style: theme.textTheme.bodySmall),
              ],
            ),
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
                    _page = 0;
                  }),
                ),
            ],
            rows: [
              for (final row in pageRows)
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
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 156,
              child: DropdownButton<int>(
                key: const ValueKey('table-page-size'),
                value: _pageSize,
                isExpanded: true,
                dropdownColor: theme.colors.surface,
                style: theme.textTheme.labelMedium,
                iconEnabledColor: theme.colors.accent,
                items: const [
                  DropdownMenuItem(value: 5, child: Text('5 行')),
                  DropdownMenuItem(value: 10, child: Text('10 行')),
                  DropdownMenuItem(value: 0, child: Text('全部')),
                ],
                onChanged: (size) {
                  if (size != null) {
                    setState(() {
                      _pageSize = size;
                      _page = 0;
                    });
                  }
                },
              ),
            ),
            LuminaButton(
              key: const ValueKey('table-previous-page'),
              primary: false,
              onPressed: _page == 0 ? null : () => setState(() => _page--),
              child: const Text('上一页'),
            ),
            LuminaButton(
              key: const ValueKey('table-next-page'),
              primary: false,
              onPressed: _page + 1 >= pageCount
                  ? null
                  : () => setState(() => _page++),
              child: const Text('下一页'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '第 ${_page + 1} / $pageCount 页 · 本页 ${pageRows.length} 行',
          key: const ValueKey('table-page-status'),
          style: theme.textTheme.bodySmall,
        ),
        Text(
          'CSV 包含全部 ${rows.length} 条筛选结果，按当前顺序导出。',
          style: theme.textTheme.bodySmall,
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
}
