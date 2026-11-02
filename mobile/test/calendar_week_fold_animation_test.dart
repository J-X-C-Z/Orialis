import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/calendar/calendar_week_layout.dart';
import 'package:orialis_mobile/pages/calendar/calendar_week_view.dart';

final _monday = DateTime(2026, 11, 2);
final _event = CalendarEvent(
  id: 'event',
  title: '课程',
  startAt: DateTime(2026, 11, 2, 8).toIso8601String(),
  endAt: DateTime(2026, 11, 2, 9).toIso8601String(),
  allDay: false,
  important: false,
  version: 1,
  remoteVersion: 0,
  localRevision: 0,
  createdAt: '',
  updatedAt: '',
  syncStatus: 'synced',
);

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.reduced = false, this.onCreate});
  final bool reduced;
  final ValueChanged<DateTime>? onCreate;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool collapsed = false;
  void fold(bool value) => setState(() => collapsed = value);
  @override
  Widget build(BuildContext context) => WidgetsApp(
    color: const Color(0xff000000),
    builder: (context, _) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: widget.reduced),
      child: LuminaTheme(
        child: CalendarWeekView(
          date: _monday,
          collapseFreeHours: collapsed,
          eventsOn: (day) => day.day == 2 ? [_event] : const [],
          tasksOn: (_) => const [],
          onSelect: (_) {},
          onEvent: (_) {},
          onCreate: widget.onCreate ?? (_) {},
          onAgenda: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  final entries = layoutCalendarDay(_monday, [_event]);
  final full = CalendarWeekAxis(entries).extent;
  final folded = CalendarWeekAxis(entries, collapsed: true).extent;
  final column = find.byKey(const ValueKey('calendar-week-day-2026-11-03'));
  final event = find.byKey(
    const ValueKey('calendar-week-event-2026-11-02-event'),
  );
  final hours = find.byKey(const PageStorageKey('calendar-week-hours'));

  test(
    'partial axes interpolate free space and retain reversible minute mapping',
    () {
      for (final progress in [0.0, .2, .5, .8, 1.0]) {
        final axis = CalendarWeekAxis(entries, collapseProgress: progress);
        expect(axis.extent, closeTo(full + (folded - full) * progress, 1e-8));
        expect(
          axis.offsetForMinute(540) - axis.offsetForMinute(480),
          closeTo(72, 1e-8),
        );
        for (var minute = 0.0; minute <= 1440; minute += 7) {
          expect(
            axis.minuteForOffset(axis.offsetForMinute(minute)),
            closeTo(minute, 1e-8),
          );
        }
      }
    },
  );

  testWidgets(
    'fold changes real geometry continuously and reverses from the current frame',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      DateTime? created;
      await tester.pumpWidget(
        _Harness(key: key, onCreate: (date) => created = date),
      );
      await tester.pumpAndSettle();
      final eventTop =
          tester.getTopLeft(event).dy - tester.getTopLeft(column).dy;
      key.currentState!.fold(true);
      await tester.pump();
      expect(tester.getSize(column).height, closeTo(full, .01));
      await tester.pump(const Duration(milliseconds: 90));
      final middle = tester.getSize(column).height;
      expect(middle, allOf(greaterThan(folded), lessThan(full)));
      final middleEventTop =
          tester.getTopLeft(event).dy - tester.getTopLeft(column).dy;
      expect(middleEventTop, allOf(greaterThan(28), lessThan(eventTop)));
      final progress = (full - middle) / (full - folded);
      final axis = CalendarWeekAxis(entries, collapseProgress: progress);
      await tester.tapAt(
        tester.getTopLeft(column) + Offset(10, axis.offsetForMinute(570)),
      );
      expect(created, DateTime(2026, 11, 3, 9, 30));
      key.currentState!.fold(false);
      await tester.pump();
      expect(tester.getSize(column).height, closeTo(middle, .01));
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        tester.getSize(column).height,
        allOf(greaterThan(middle), lessThan(full)),
      );
      expect(event, findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.getSize(column).height, closeTo(full, .01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion folds and unfolds in one frame', (tester) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, reduced: true));
    await tester.pumpAndSettle();
    key.currentState!.fold(true);
    await tester.pump();
    expect(tester.getSize(column).height, folded);
    key.currentState!.fold(false);
    await tester.pump();
    expect(tester.getSize(column).height, full);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a held scroll gesture keeps control while folding', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final controller = tester.widget<SingleChildScrollView>(hours).controller!;
    final gesture = await tester.startGesture(tester.getCenter(hours));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(controller.position.isScrollingNotifier.value, isTrue);
    final offset = controller.offset;
    key.currentState!.fold(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 35));
    expect(controller.offset, closeTo(offset, .01));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
