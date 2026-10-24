import 'dart:async';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../../../app/app.dart';
import '../../../core/config/app_config.dart';
import '../application/response_action_service.dart';
import 'chat_attachment.dart';

final responseActionServiceProvider = Provider<ResponseActionService>(
  (ref) => ResponseActionService(ref.watch(eventRepositoryProvider)),
);

class ResponseActionBlock extends StatelessWidget {
  const ResponseActionBlock({
    required this.data,
    required this.enabled,
    required this.scope,
    super.key,
  });
  final Map<String, dynamic> data;
  final bool enabled;
  final String scope;

  @override
  Widget build(BuildContext context) {
    final gallery = [
      for (final raw in data['items'] as List)
        if ((raw['mimeType'] as String? ?? '').startsWith('image/'))
          <String, dynamic>{
            'id': raw['id'],
            'name': raw['name'] ?? raw['label'],
            'mimeType': raw['mimeType'],
          },
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final raw in data['items'] as List)
          if (data['type'] == 'media')
            ChatAttachmentTile(
              gallery: gallery,
              attachment: {
                'id': raw['id'],
                'name': raw['name'] ?? raw['label'],
                'mimeType': raw['mimeType'],
              },
            )
          else if (!enabled)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(raw['label'] as String),
                  LuminaSelectableText(
                    _actionDetails(Map<String, dynamic>.from(raw as Map)),
                  ),
                  LuminaButton(
                    onPressed: null,
                    child: Text(raw['kind'] == 'task' ? '预览并创建任务' : '预览并创建日程'),
                  ),
                ],
              ),
            )
          else
            _ActionItem(
              key: ValueKey('$scope:${raw['id']}'),
              item: Map<String, dynamic>.from(raw as Map),
              scope: scope,
              enabled: enabled,
            ),
      ],
    );
  }
}

class _ActionItem extends ConsumerStatefulWidget {
  const _ActionItem({
    required this.item,
    required this.scope,
    required this.enabled,
    super.key,
  });
  final Map<String, dynamic> item;
  final String scope;
  final bool enabled;

  @override
  ConsumerState<_ActionItem> createState() => _ActionItemState();
}

class _ActionItemState extends ConsumerState<_ActionItem> {
  ResponseActionReceipt? _receipt;
  String? _error;
  bool _busy = false, _loading = true, _identityChanged = false;
  late AppConfig _config;
  StreamSubscription<dynamic>? _changes;

  @override
  void initState() {
    super.initState();
    _config = ref.read(appConfigProvider);
    _config.addIdentityListener(_invalidate);
    final db = ref.read(responseActionServiceProvider).database;
    _changes = db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            db.tasks,
            db.calendarEvents,
            db.outboxMutations,
          ]),
        )
        .listen((_) => unawaited(_reload()));
    unawaited(_reload());
  }

  Future<void> _invalidate() async {
    if (mounted) setState(() => _identityChanged = true);
  }

  Future<void> _reload() async {
    try {
      final value = await ref
          .read(responseActionServiceProvider)
          .lookup(widget.scope, widget.item);
      if (mounted && !_identityChanged) {
        setState(() {
          _receipt = value;
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '暂时无法读取创建状态，请重试';
        });
      }
    }
  }

  Future<void> _create() async {
    if (_busy || _receipt != null || !widget.enabled || _identityChanged) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.item['kind'] == 'task' ? '创建任务' : '创建日程'),
          content: SingleChildScrollView(child: Text(_details())),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认创建'),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          _identityChanged ||
          !widget.enabled) {
        return;
      }
      final receipt = await ref
          .read(responseActionServiceProvider)
          .create(widget.scope, widget.item);
      if (mounted && !_identityChanged) setState(() => _receipt = receipt);
    } catch (_) {
      if (mounted) setState(() => _error = '创建失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _details() => _actionDetails(widget.item);

  @override
  void dispose() {
    _config.removeIdentityListener(_invalidate);
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.item['label'] as String,
          style: LuminaTheme.of(context).textTheme.recessedTitle,
        ),
        const SizedBox(height: 4),
        LuminaSelectableText(_details()),
        const SizedBox(height: 8),
        if (_identityChanged)
          const Text('登录已改变，请重新打开此消息')
        else if (_receipt != null)
          Text(_receipt!.message)
        else
          LuminaButton(
            onPressed: _busy || _loading || !widget.enabled ? null : _create,
            child: Text(
              _busy
                  ? '正在处理…'
                  : widget.item['kind'] == 'task'
                  ? '预览并创建任务'
                  : '预览并创建日程',
            ),
          ),
        if (_error != null) ...[
          Text(_error!),
          TextButton(
            onPressed: _busy ? null : _reload,
            child: const Text('重试读取状态'),
          ),
        ],
      ],
    ),
  );
}

String _actionDetails(Map<String, dynamic> item) => [
  item['title'] as String,
  if (item['notes'] != null) item['notes'] as String,
  if (item['due'] != null) '截止日期：${item['due']}',
  if (item['startAt'] != null) '开始：${item['startAt']}',
  if (item['endAt'] != null) '结束：${item['endAt']}',
  if (item['location'] != null) '地点：${item['location']}',
].join('\n');
