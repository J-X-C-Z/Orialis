import 'dart:async';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../../../app/app.dart';
import '../../../core/config/app_config.dart';
import '../application/response_action_service.dart';
import 'chat_attachment.dart';
import 'response_schedule_editor.dart';

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

  Map<String, dynamic> _item(dynamic raw) => {
    ...Map<String, dynamic>.from(raw as Map),
    if (data['type'] == 'agenda') 'kind': 'schedule',
  };

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
                  LuminaSelectableText(_actionDetails(_item(raw))),
                  if (raw['kind'] == 'schedule' || data['type'] == 'agenda')
                    const Text('待确认'),
                  LuminaButton(
                    onPressed: null,
                    child: Text(
                      raw['kind'] == 'task'
                          ? '预览并创建任务'
                          : data['type'] == 'agenda'
                          ? '确认添加日程'
                          : '预览并创建日程',
                    ),
                  ),
                ],
              ),
            )
          else
            _ActionItem(
              key: ValueKey('$scope:${raw['id']}'),
              item: _item(raw),
              agenda: data['type'] == 'agenda',
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
    required this.agenda,
    required this.scope,
    required this.enabled,
    super.key,
  });
  final Map<String, dynamic> item;
  final bool agenda;
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

  @override
  void didUpdateWidget(covariant _ActionItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope ||
        !mapEquals(oldWidget.item, widget.item)) {
      _receipt = null;
      _loading = true;
      unawaited(_reload());
    }
  }

  Future<void> _invalidate() async {
    if (mounted) setState(() => _identityChanged = true);
  }

  Future<void> _reload() async {
    final item = widget.item;
    final scope = widget.scope;
    try {
      final value = await ref
          .read(responseActionServiceProvider)
          .lookup(scope, item);
      if (mounted &&
          !_identityChanged &&
          scope == widget.scope &&
          mapEquals(item, widget.item)) {
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
    if (_busy ||
        _loading ||
        _receipt != null ||
        !widget.enabled ||
        _identityChanged) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final original = widget.item;
      final scope = widget.scope;
      Map<String, dynamic>? overrides;
      final bool confirmed;
      if (original['kind'] == 'schedule') {
        overrides = await showLuminaDialog<Map<String, dynamic>>(
          context: context,
          builder: (_) => ResponseScheduleEditor(item: original),
        );
        confirmed = overrides != null;
      } else {
        confirmed =
            await showLuminaDialog<bool>(
              context: context,
              builder: (dialogContext) => LuminaDialog(
                title: '创建任务',
                content: Text(_details()),
                actions: [
                  LuminaButton(
                    primary: false,
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                  LuminaButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('确认创建'),
                  ),
                ],
              ),
            ) ??
            false;
      }
      if (confirmed != true ||
          !mounted ||
          _identityChanged ||
          !widget.enabled ||
          widget.scope != scope ||
          !mapEquals(original, widget.item)) {
        return;
      }
      final receipt = await ref
          .read(responseActionServiceProvider)
          .create(scope, original, overrides: overrides);
      if (mounted &&
          !_identityChanged &&
          widget.scope == scope &&
          mapEquals(original, widget.item)) {
        setState(() => _receipt = receipt);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '创建失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _details() =>
      _actionDetails({...widget.item, ...?_receipt?.savedSchedule});

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
        if (widget.item['kind'] == 'schedule' && _receipt == null)
          const Text('待确认'),
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
                  : widget.agenda
                  ? '确认添加日程'
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
  if (item['kind'] == 'schedule') responseScheduleDetails(item),
  if (item['location'] != null) '地点：${item['location']}',
].join('\n');
