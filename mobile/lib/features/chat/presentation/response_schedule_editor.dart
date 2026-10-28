import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

import '../domain/response_action_schema.dart';

String responseScheduleDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${_two(value.month)}-${_two(value.day)}';
String responseScheduleTime(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}';
String _two(int value) => value.toString().padLeft(2, '0');

String responseScheduleZone(DateTime value) {
  final minutes = value.timeZoneOffset.inMinutes;
  return '${value.timeZoneName} (UTC${minutes < 0 ? '-' : '+'}'
      '${_two(minutes.abs() ~/ 60)}:${_two(minutes.abs() % 60)})';
}

String responseScheduleDetails(Map<String, dynamic> item) {
  final start = DateTime.parse(item['startAt'] as String).toLocal();
  final end = DateTime.parse(item['endAt'] as String).toLocal();
  final duration = end.difference(start);
  return [
    '开始：${responseScheduleDate(start)} ${responseScheduleTime(start)}',
    '结束：${responseScheduleDate(end)} ${responseScheduleTime(end)}',
    '时长：${duration.inHours}小时${duration.inMinutes % 60}分钟',
    '设备本地时区：${responseScheduleZone(start)}',
    if (start.timeZoneOffset != end.timeZoneOffset)
      '结束时区：${responseScheduleZone(end)}',
  ].join('\n');
}

/// Returns edits only; persistence happens after this explicit confirmation.
class ResponseScheduleEditor extends StatefulWidget {
  const ResponseScheduleEditor({required this.item, super.key});
  final Map<String, dynamic> item;

  @override
  State<ResponseScheduleEditor> createState() => _ResponseScheduleEditorState();
}

class _ResponseScheduleEditorState extends State<ResponseScheduleEditor> {
  late final _title = TextEditingController(
    text: widget.item['title'] as String,
  );
  late final _location = TextEditingController(
    text: widget.item['location'] as String?,
  );
  late final _notes = TextEditingController(
    text: widget.item['notes'] as String?,
  );
  late DateTime _start = DateTime.parse(widget.item['startAt'] as String)
      .toLocal();
  late DateTime _end = DateTime.parse(widget.item['endAt'] as String).toLocal();
  String? _error;
  bool _invalidLocalTime = false;

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pick(bool start, bool date) async {
    FocusScope.of(context).unfocus();
    final current = start ? _start : _end;
    final picked = date
        ? await showLuminaDatePicker(
            context: context,
            initialDate: current,
            firstDate: DateTime(0),
            lastDate: DateTime(9999, 12, 31),
          )
        : await showLuminaTimePicker(
            context: context,
            // Pick the wall-clock time independently, then reject DST gaps below.
            initialTime: DateTime(2000, 1, 1, current.hour, current.minute),
          );
    if (picked == null || !mounted) return;
    final year = date ? picked.year : current.year;
    final month = date ? picked.month : current.month;
    final day = date ? picked.day : current.day;
    final hour = date ? current.hour : picked.hour;
    final minute = date ? current.minute : picked.minute;
    final unchanged =
        year == current.year &&
        month == current.month &&
        day == current.day &&
        hour == current.hour &&
        minute == current.minute;
    // Preserve the original instant even in the repeated hour when DST ends.
    final next = unchanged
        ? current
        : DateTime(
            year,
            month,
            day,
            hour,
            minute,
            current.second,
            current.millisecond,
            current.microsecond,
          );
    setState(() {
      if (next.year != year ||
          next.month != month ||
          next.day != day ||
          next.hour != hour ||
          next.minute != minute) {
        _error = '此时间在设备本地时区不存在，请重新选择';
        _invalidLocalTime = true;
        return;
      }
      if (start) {
        _start = next;
      } else {
        _end = next;
      }
      _error = null;
      _invalidLocalTime = false;
    });
  }

  void _confirm() {
    if (_invalidLocalTime) return;
    final edits = <String, dynamic>{
      'title': _title.text.trim(),
      'startAt': _start.toUtc().toIso8601String(),
      'endAt': _end.toUtc().toIso8601String(),
      'location': _location.text.trim().isEmpty ? null : _location.text.trim(),
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    };
    if (!_start.isBefore(_end)) {
      setState(() => _error = '结束时间必须晚于开始时间');
    } else if (!validateActionResponseBlock({
      'type': 'actions',
      'items': [
        {...widget.item, ...edits},
      ],
    })) {
      setState(() => _error = '请填写标题，并检查字段长度与时间');
    } else {
      Navigator.pop(context, edits);
    }
  }

  @override
  Widget build(BuildContext context) => LuminaDialog(
    title: '确认日程',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LuminaTextField(controller: _title, label: '标题', maxLength: 240),
        const SizedBox(height: 16),
        for (final start in [true, false]) ...[
          Text(start ? '开始' : '结束'),
          const SizedBox(height: 8),
          LuminaButton(
            key: ValueKey(start ? 'schedule-start-date' : 'schedule-end-date'),
            primary: false,
            onPressed: () => _pick(start, true),
            child: Text(responseScheduleDate(start ? _start : _end)),
          ),
          const SizedBox(height: 8),
          LuminaButton(
            key: ValueKey(start ? 'schedule-start-time' : 'schedule-end-time'),
            primary: false,
            onPressed: () => _pick(start, false),
            child: Text(responseScheduleTime(start ? _start : _end)),
          ),
          const SizedBox(height: 8),
          Text('设备本地时区：${responseScheduleZone(start ? _start : _end)}'),
          const SizedBox(height: 16),
        ],
        LuminaTextField(controller: _location, label: '地点', maxLength: 240),
        const SizedBox(height: 16),
        LuminaTextField(
          controller: _notes,
          label: '备注',
          maxLength: 4000,
          maxLines: 4,
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, semanticsLabel: _error),
        ],
      ],
    ),
    actions: [
      LuminaButton(
        primary: false,
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      LuminaButton(onPressed: _confirm, child: const Text('确认添加')),
    ],
  );
}
