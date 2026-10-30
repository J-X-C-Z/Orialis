import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumina_ui/lumina_ui.dart';

import '../../app/app.dart';
import '../../core/database/app_database.dart';
import '../../pages/shared/page_parts.dart';

/// Manual consent belongs to this schedule, never to a reminder or sync event.
class ScheduleTrackingButton extends ConsumerStatefulWidget {
  const ScheduleTrackingButton({required this.eventId, super.key});
  final String eventId;

  @override
  ConsumerState<ScheduleTrackingButton> createState() =>
      _ScheduleTrackingButtonState();
}

class _ScheduleTrackingButtonState extends ConsumerState<ScheduleTrackingButton>
    with WidgetsBindingObserver {
  late final Stream<List<CalendarEvent>> _events;
  Timer? _timer;
  String? _trackedId;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _events = ref.read(scheduleRepositoryProvider).watchAll();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reload());
    // Reconcile dismissal and time boundaries without reposting notifications.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy) unawaited(_reload());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reload());
  }

  Future<void> _reload() async {
    final system = ref.read(systemIntegrationProvider);
    final tracked = await system?.trackedScheduleId();
    if (mounted) {
      setState(() {
        _trackedId = tracked;
        _busy = false;
      });
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final system = ref.read(systemIntegrationProvider);
    if (system == null) return;
    setState(() => _busy = true);
    try {
      if (!system.enabled) {
        if (mounted) showLuminaMessage(context, '请先在「系统提醒与桌面」开启提醒与桌面');
        return;
      }
      final tracked = await system.trackedScheduleId();
      if (!mounted) return;
      if (tracked != null && tracked != widget.eventId) {
        showLuminaMessage(context, '正在跟踪另一个日程，请先在其详情或通知中停止跟踪');
        return;
      }
      if (tracked != widget.eventId) {
        final status = await system.status();
        if (!mounted) return;
        if (status?['notificationsEnabled'] != true) {
          showLuminaMessage(context, '请在「系统提醒与桌面」允许通知后再开启跟踪');
          return;
        }
      }
      final stopped = tracked == widget.eventId;
      final success = stopped
          ? await system.stopScheduleTracking(widget.eventId)
          : await system.startScheduleTracking(widget.eventId);
      if (!mounted) return;
      showLuminaMessage(
        context,
        success
            ? (stopped ? '已停止跟踪' : '已开启跟踪，显示方式由手机系统决定')
            : '暂时无法跟踪，请确认日程正在进行、账号有效且通知已允许',
      );
    } finally {
      if (mounted) await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final system = ref.watch(systemIntegrationProvider);
    if (system == null || !system.supported) return const SizedBox.shrink();
    return StreamBuilder<List<CalendarEvent>>(
      stream: _events,
      builder: (context, snapshot) {
        final event = snapshot.data
            ?.where((row) => row.id == widget.eventId)
            .firstOrNull;
        final start = DateTime.tryParse(event?.startAt ?? '');
        final end = DateTime.tryParse(event?.endAt ?? '');
        final now = DateTime.now();
        if (event == null ||
            event.deletedAt != null ||
            start == null ||
            end == null ||
            start.isAfter(now) ||
            !end.isAfter(now)) {
          return const SizedBox.shrink();
        }
        final tracking = _trackedId == event.id;
        return ContentStack(
          gap: 8,
          children: [
            LuminaButton(
              primary: false,
              onPressed: _busy ? null : _toggle,
              child: Text(tracking ? '停止跟踪此日程' : '跟踪此日程'),
            ),
            QuietLabel(
              tracking ? '通知显示日程名称与剩余时间，结束后自动撤下' : '手动开启后在系统通知中跟踪；支持的系统可在岛上显示',
            ),
          ],
        );
      },
    );
  }
}
