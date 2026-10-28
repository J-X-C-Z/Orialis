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
  bool _toolsExpanded = false;

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
      _toolsExpanded = false;
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

  void _sortBy(int? column, bool ascending) => setState(() {
    _sortColumn = column;
    _ascending = ascending;
    _page = 0;
  });

  // Old messages may have only a timestamp or row number as their label.
  // Extract a readable cell in that case; never invent facts to summarize it.
  String _summary(Map<String, dynamic> row) {
    final label = '${row['label']}'.trim();
    bool placeholder(String value) => RegExp(
      r'^(?:详情|展开行|记录|第?\s*\d+\s*行|(?:row|record|记录)[ -]?\d+|[\d\s:/年月日.\-–]+)$',
      caseSensitive: false,
    ).hasMatch(value);
    if (label.isNotEmpty && !placeholder(label)) return label;
    for (final cell in row['cells'] as List) {
      final value = '$cell'.trim();
      if (value.isNotEmpty && !placeholder(value)) return value;
    }
    final columns = (widget.data['columns'] as List).cast<String>();
    final cells = row['cells'] as List;
    return [
      for (var i = 0; i < columns.length && i < 2; i++)
        '${columns[i]}：${cells[i]}',
    ].join(' · ');
  }

  Widget _compactRow(List<String> columns, Map<String, dynamic> row) {
    final theme = LuminaTheme.of(context);
    final title = _summary(row);
    final cells = row['cells'] as List;
    final details = <String>[
      for (var i = 0; i < columns.length; i++)
        if ('${cells[i]}'.trim().isNotEmpty && '${cells[i]}'.trim() != title)
          '${columns[i]}：${cells[i]}',
    ];
    return Semantics(
      button: true,
      label: '查看完整详情',
      child: InkWell(
        key: ValueKey('table-row-${_items.indexOf(row)}'),
        onTap: () => _showRow(columns, row),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        details.join(' · '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 18, color: theme.colors.accent),
            ],
          ),
        ),
      ),
    );
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;
        final iconPaging =
            constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _search.text.isEmpty
                        ? '${rows.length} 条记录'
                        : '${rows.length} / ${_items.length} 条匹配',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                LuminaIconButton(
                  key: const ValueKey('table-tools'),
                  tooltip: _toolsExpanded ? '收起表格工具' : '搜索、排序与导出',
                  onPressed: () =>
                      setState(() => _toolsExpanded = !_toolsExpanded),
                  icon: Icon(
                    _toolsExpanded ? Icons.expand_less : Icons.tune,
                    size: 20,
                  ),
                ),
              ],
            ),
            if (_toolsExpanded) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: LuminaTextField(
                      key: const ValueKey('table-search'),
                      controller: _search,
                      label: '筛选表格',
                      hint: '搜索任意单元格',
                      onChanged: (_) => setState(() {
                        _page = 0;
                        _notice = null;
                      }),
                    ),
                  ),
                  if (_search.text.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    LuminaIconButton(
                      key: const ValueKey('table-clear-search'),
                      tooltip: '清除搜索',
                      onPressed: _clearSearch,
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButton<int>(
                      key: const ValueKey('table-sort-column'),
                      value: _sortColumn ?? -1,
                      isExpanded: true,
                      dropdownColor: theme.colors.surface,
                      style: theme.textTheme.bodySmall,
                      items: [
                        const DropdownMenuItem(value: -1, child: Text('原始顺序')),
                        for (var i = 0; i < columns.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              columns[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _sortBy(value == -1 ? null : value, true);
                        }
                      },
                    ),
                  ),
                  if (_sortColumn != null) ...[
                    const SizedBox(width: 8),
                    LuminaIconButton(
                      key: const ValueKey('table-sort-direction'),
                      tooltip: _ascending ? '升序，点击降序' : '降序，点击升序',
                      onPressed: () => _sortBy(_sortColumn, !_ascending),
                      icon: Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 20,
                      ),
                    ),
                    LuminaIconButton(
                      key: const ValueKey('table-clear-sort'),
                      tooltip: '恢复原始顺序',
                      onPressed: () => _sortBy(null, true),
                      icon: const Icon(Icons.restart_alt, size: 20),
                    ),
                  ],
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: LuminaButton(
                      primary: false,
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _csv()));
                        if (mounted) setState(() => _notice = 'CSV 已复制');
                      },
                      child: const Text('复制 CSV', textAlign: TextAlign.center),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LuminaButton(
                      primary: false,
                      onPressed: _saving ? null : _saveCsv,
                      child: Text(
                        _saving ? '正在导出…' : '导出 CSV',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '导出全部 ${rows.length} 条筛选结果',
                style: theme.textTheme.bodySmall,
              ),
              if (_items.length > 5)
                DropdownButton<int>(
                  key: const ValueKey('table-page-size'),
                  value: _pageSize,
                  isExpanded: true,
                  dropdownColor: theme.colors.surface,
                  style: theme.textTheme.bodySmall,
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('每页 5 行')),
                    DropdownMenuItem(value: 10, child: Text('每页 10 行')),
                    DropdownMenuItem(value: 0, child: Text('显示全部')),
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
            ],
            if (_sortColumn != null)
              Text(
                '${columns[_sortColumn!]} · ${_ascending ? '升序 ↑' : '降序 ↓'}',
                key: const ValueKey('table-sort-status'),
                style: theme.textTheme.bodySmall,
              ),
            if (rows.isEmpty)
              Padding(
                key: const ValueKey('table-empty'),
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '没有匹配结果，试试其他关键词。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (compact)
              for (var i = 0; i < pageRows.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _compactRow(columns, pageRows[i]),
              ]
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  sortColumnIndex: _sortColumn == null
                      ? null
                      : _sortColumn! + 1,
                  sortAscending: _ascending,
                  dataRowMinHeight: 48,
                  dataRowMaxHeight: double.infinity,
                  columns: [
                    const DataColumn(label: Text('摘要')),
                    for (var i = 0; i < columns.length; i++)
                      DataColumn(
                        label: Text(columns[i]),
                        onSort: (_, ascending) => _sortBy(i, ascending),
                      ),
                  ],
                  rows: [
                    for (final row in pageRows)
                      DataRow(
                        cells: [
                          DataCell(
                            SizedBox(
                              width: 220,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(
                                  _summary(row),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelMedium,
                                ),
                              ),
                            ),
                            onTap: () => _showRow(columns, row),
                          ),
                          for (final cell in row['cells'] as List)
                            DataCell(
                              SizedBox(
                                width: 180,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    '$cell',
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              onTap: () => _showRow(columns, row),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            if (pageCount > 1) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (iconPaging)
                    LuminaIconButton(
                      key: const ValueKey('table-previous-page'),
                      tooltip: '上一页',
                      onPressed: _page == 0
                          ? null
                          : () => setState(() => _page--),
                      icon: const Icon(Icons.chevron_left),
                    )
                  else
                    Expanded(
                      child: LuminaButton(
                        key: const ValueKey('table-previous-page'),
                        primary: false,
                        onPressed: _page == 0
                            ? null
                            : () => setState(() => _page--),
                        child: const Text('上一页'),
                      ),
                    ),
                  if (iconPaging)
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '${_page + 1} / $pageCount',
                            key: const ValueKey('table-page-status'),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '${_page + 1} / $pageCount',
                        key: const ValueKey('table-page-status'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (iconPaging)
                    LuminaIconButton(
                      key: const ValueKey('table-next-page'),
                      tooltip: '下一页',
                      onPressed: _page + 1 >= pageCount
                          ? null
                          : () => setState(() => _page++),
                      icon: const Icon(Icons.chevron_right),
                    )
                  else
                    Expanded(
                      child: LuminaButton(
                        key: const ValueKey('table-next-page'),
                        primary: false,
                        onPressed: _page + 1 >= pageCount
                            ? null
                            : () => setState(() => _page++),
                        child: const Text('下一页'),
                      ),
                    ),
                ],
              ),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 8),
              Text(_notice!, style: theme.textTheme.bodySmall),
            ],
          ],
        );
      },
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
