import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/theme/app_theme.dart';
import '../../core/database/app_database.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  DateTime _date = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(eventRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('${_date.year}/${_date.month}/${_date.day}'),
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createEvent(context),
        icon: const Icon(Icons.add),
        label: const Text('新增日程'),
      ),
      body: StreamBuilder<List<CalendarEvent>>(
        stream: repository.watchCalendarEventsForDate(_date),
        builder: (context, snapshot) {
          final events = snapshot.data ?? const [];
          if (events.isEmpty) {
            return const Center(child: Text('今天没有已安排的时间段。'));
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
                        ref
                            .read(eventRepositoryProvider)
                            .deleteCalendarEvent(event);
                      }
                    },
                    itemBuilder: (_) => const [
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
    var draft = '';
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增日程'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => draft = value,
          decoration: const InputDecoration(labelText: '标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    final start = DateTime(_date.year, _date.month, _date.day, 9);
    await ref
        .read(eventRepositoryProvider)
        .createCalendarEvent(
          title: title,
          startAt: start,
          endAt: start.add(const Duration(hours: 1)),
        );
  }

  String _time(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
