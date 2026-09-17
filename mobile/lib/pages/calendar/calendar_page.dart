import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/design/design_components.dart';
import '../../app/design/design_tokens.dart';
import '../../core/database/app_database.dart';

// The storage/API migration keeps CalendarEvent for compatibility. The page
// speaks in the product term: Schedule. Task never enters this screen.
typedef Schedule = CalendarEvent;

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  DateTime _date = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(scheduleRepositoryProvider);
    return OrialisPageScaffold(
      title: '${_date.year}/${_date.month}/${_date.day}',
      subtitle: '日程 · 只显示已安排的时间段',
      padding: EdgeInsets.zero,
      actions: [
        IconButton(
          tooltip: '选择日期',
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime(2035),
              initialDate: _date,
            );
            if (picked != null) {
              setState(() => _date = picked);
            }
          },
          icon: const Icon(Icons.event_outlined),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createEvent(context),
        icon: const Icon(Icons.add),
        label: const Text('新增日程'),
      ),
      body: StreamBuilder<List<Schedule>>(
        stream: repository.watchForDate(_date),
        builder: (context, snapshot) {
          final events = snapshot.data ?? const [];
          if (events.isEmpty) {
            return OrialisEmptyState(
              text: '${_date.month}月${_date.day}日没有已安排的时间段。',
              card: false,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              8,
              AppSpacing.page,
              96,
            ),
            itemCount: events.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, index) {
              final event = events[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.schedule_outlined),
                  title: Text(event.title),
                  subtitle: Text(
                    '${_time(event.startAt)}–${_time(event.endAt)}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'delete') {
                        ref.read(scheduleRepositoryProvider).delete(event);
                      }
                      if (action == 'edit') {
                        _editEvent(context, event);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _createEvent(BuildContext context) async {
    final draft = await _showScheduleEditor(context, date: _date);
    if (draft == null) return;
    await ref
        .read(scheduleRepositoryProvider)
        .create(
          title: draft.title,
          startAt: draft.startAt,
          endAt: draft.endAt,
          allDay: draft.allDay,
          location: draft.location,
          description: draft.description,
          reminderMinutes: draft.reminderMinutes,
        );
  }

  Future<void> _editEvent(BuildContext context, Schedule event) async {
    final draft = await _showScheduleEditor(
      context,
      event: event,
      date: DateTime.parse(event.startAt),
    );
    if (draft == null) return;
    await ref
        .read(scheduleRepositoryProvider)
        .update(
          event,
          title: draft.title,
          startAt: draft.startAt,
          endAt: draft.endAt,
          allDay: draft.allDay,
          location: draft.location,
          description: draft.description,
          reminderMinutes: draft.reminderMinutes,
        );
  }

  Future<_ScheduleDraft?> _showScheduleEditor(
    BuildContext context, {
    Schedule? event,
    required DateTime date,
  }) async {
    final title = TextEditingController(text: event?.title ?? '');
    final location = TextEditingController(text: event?.location ?? '');
    final description = TextEditingController(text: event?.description ?? '');
    final reminder = TextEditingController(
      text: event?.reminderMinutes?.toString() ?? '',
    );
    final start = TextEditingController(
      text:
          event?.startAt ??
          DateTime(date.year, date.month, date.day, 9).toIso8601String(),
    );
    final end = TextEditingController(
      text:
          event?.endAt ??
          DateTime(date.year, date.month, date.day, 10).toIso8601String(),
    );
    var allDay = event?.allDay ?? false;
    try {
      return await showDialog<_ScheduleDraft>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(event == null ? '新增日程' : '编辑日程'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: event == null,
                    decoration: const InputDecoration(labelText: '标题'),
                  ),
                  TextField(
                    controller: start,
                    decoration: const InputDecoration(
                      labelText: '开始时间 ISO-8601',
                    ),
                  ),
                  TextField(
                    controller: end,
                    decoration: const InputDecoration(
                      labelText: '结束时间 ISO-8601',
                    ),
                  ),
                  TextField(
                    controller: location,
                    decoration: const InputDecoration(labelText: '地点'),
                  ),
                  TextField(
                    controller: description,
                    decoration: const InputDecoration(labelText: '描述'),
                  ),
                  TextField(
                    controller: reminder,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '提醒分钟'),
                  ),
                  SwitchListTile(
                    title: const Text('全天'),
                    value: allDay,
                    onChanged: (value) => setState(() => allDay = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final startAt = DateTime.tryParse(start.text.trim());
                  final endAt = DateTime.tryParse(end.text.trim());
                  final minutes = int.tryParse(reminder.text.trim());
                  if (title.text.trim().isEmpty ||
                      startAt == null ||
                      endAt == null ||
                      !startAt.isBefore(endAt) ||
                      (minutes != null && minutes < 0)) {
                    return;
                  }
                  Navigator.pop(
                    dialogContext,
                    _ScheduleDraft(
                      title: title.text.trim(),
                      startAt: startAt,
                      endAt: endAt,
                      allDay: allDay,
                      location: location.text.trim().isEmpty
                          ? null
                          : location.text.trim(),
                      description: description.text.trim().isEmpty
                          ? null
                          : description.text.trim(),
                      reminderMinutes: minutes,
                    ),
                  );
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      title.dispose();
      start.dispose();
      end.dispose();
      location.dispose();
      description.dispose();
      reminder.dispose();
    }
  }

  String _time(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _ScheduleDraft {
  const _ScheduleDraft({
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.allDay,
    this.location,
    this.description,
    this.reminderMinutes,
  });
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;
  final String? location;
  final String? description;
  final int? reminderMinutes;
}
