import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/calendar/calendar_week_view.dart';

const _selectionBar = ValueKey('calendar-week-selection-bar');
const _hours = PageStorageKey('calendar-week-hours');

class _WeekHarness extends StatefulWidget {
  const _WeekHarness({
    required this.initialDate,
    this.reducedMotion = false,
    super.key,
  });

  final DateTime initialDate;
  final bool reducedMotion;

  @override
  State<_WeekHarness> createState() => _WeekHarnessState();
}

class _WeekHarnessState extends State<_WeekHarness> {
  late var _date = widget.initialDate;

  void select(DateTime date) => setState(() => _date = date);

  @override
  Widget build(BuildContext context) => WidgetsApp(
    color: const Color(0xff000000),
    builder: (context, _) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(disableAnimations: widget.reducedMotion),
      child: LuminaTheme(
        child: CalendarWeekView(
          date: _date,
          eventsOn: (_) => const <CalendarEvent>[],
          tasksOn: (_) => const <Task>[],
          onSelect: select,
          onEvent: (_) {},
          onCreate: (_) {},
          onAgenda: (_) {},
        ),
      ),
    ),
  );
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('compact gutter shows only the hour without crowding days', (
    tester,
  ) async {
    _size(tester, const Size(360, 800));
    await tester.pumpWidget(_WeekHarness(initialDate: DateTime(2026, 11, 2)));
    await tester.pumpAndSettle();

    final monday = tester.getRect(
      find.byKey(const ValueKey('calendar-week-date-2026-11-02')),
    );
    final time = find.byKey(const ValueKey('calendar-week-time-8'));
    expect(monday.left, closeTo(30, .01));
    expect(tester.widget<Text>(time).data, '08');
    expect(tester.getSize(time).height, lessThan(20));
  });

  testWidgets(
    'same-week selection moves only the shared bar and keeps scroll offset',
    (tester) async {
      _size(tester, const Size(360, 800));
      await tester.pumpWidget(_WeekHarness(initialDate: DateTime(2026, 11, 2)));
      await tester.pumpAndSettle();

      final timeline = tester.element(
        find.byKey(const ValueKey('calendar-week-timeline')),
      );
      final controller = tester
          .widget<SingleChildScrollView>(find.byKey(_hours))
          .controller!;
      final scrollOffset = controller.offset;
      final start = tester.getRect(find.byKey(_selectionBar)).left;
      final target = tester
          .getRect(find.byKey(const ValueKey('calendar-week-date-2026-11-04')))
          .left;

      await tester.tap(
        find.byKey(const ValueKey('calendar-week-date-2026-11-04')),
      );
      await tester.pump();
      var previous = tester.getRect(find.byKey(_selectionBar)).left;
      expect(previous, closeTo(start, .01));

      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final current = tester.getRect(find.byKey(_selectionBar)).left;
        expect(current, greaterThanOrEqualTo(start - .01));
        expect(current, lessThanOrEqualTo(target + .01));
        expect(current, greaterThanOrEqualTo(previous - .01));
        if (frame == 5) {
          expect(current, greaterThan(start));
          expect(current, lessThan(target));
        }
        previous = current;
      }
      expect(previous, lessThan(target));

      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tester.getRect(find.byKey(_selectionBar)).left,
        closeTo(target, .01),
      );
      expect(controller.offset, scrollOffset);
      expect(
        tester.element(find.byKey(const ValueKey('calendar-week-timeline'))),
        same(timeline),
      );
    },
  );

  testWidgets('reduced motion changes the selection in one frame', (
    tester,
  ) async {
    _size(tester, const Size(360, 800));
    await tester.pumpWidget(
      _WeekHarness(initialDate: DateTime(2026, 11, 2), reducedMotion: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('calendar-week-date-2026-11-04')),
    );
    await tester.pump();

    final target = tester
        .getRect(find.byKey(const ValueKey('calendar-week-date-2026-11-04')))
        .left;
    expect(
      tester.getRect(find.byKey(_selectionBar)).left,
      closeTo(target, .01),
    );
  });

  testWidgets('cross-week selection resets instead of sliding', (tester) async {
    _size(tester, const Size(360, 800));
    final harness = GlobalKey<_WeekHarnessState>();
    await tester.pumpWidget(
      _WeekHarness(key: harness, initialDate: DateTime(2026, 11, 2)),
    );
    await tester.pumpAndSettle();

    harness.currentState!.select(DateTime(2026, 11, 13));
    await tester.pump();

    final target = tester
        .getRect(find.byKey(const ValueKey('calendar-week-date-2026-11-13')))
        .left;
    expect(
      tester.getRect(find.byKey(_selectionBar)).left,
      closeTo(target, .01),
    );
  });
}
