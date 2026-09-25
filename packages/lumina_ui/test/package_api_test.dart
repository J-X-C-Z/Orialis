import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget app(Widget child, {Locale locale = const Locale('en')}) => WidgetsApp(
  color: const Color(0xff000000),
  locale: locale,
  supportedLocales: LuminaLocalizations.supportedLocales,
  localizationsDelegates: const [LuminaLocalizations.delegate],
  builder: (context, _) => child,
);

class _FailingStore implements LuminaCardStore {
  @override
  bool? readExpanded(String id) => null;
  @override
  Future<void> writeExpanded(String id, bool expanded) async =>
      throw StateError('offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('switch shares the recessed track and glass selection lens', (
    tester,
  ) async {
    var value = false;
    await tester.pumpWidget(
      app(
        LuminaTheme(
          child: Center(
            child: StatefulBuilder(
              builder: (context, update) => LuminaSwitch(
                value: value,
                onChanged: (next) => update(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('lumina-selection-well')), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LuminaSwitch),
        matching: find.byType(LuminaSurface),
      ),
      findsNothing,
    );
    final lens = find.byKey(const ValueKey('lumina-selection-lens'));
    final start = tester.getTopLeft(lens);
    await tester.tap(find.byType(LuminaSwitch));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(tester.getTopLeft(lens).dx, greaterThan(start.dx));
    await tester.tap(find.byType(LuminaSwitch));
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect((tester.getTopLeft(lens) - start).distance, lessThan(.01));
    final hold = await tester.startGesture(tester.getCenter(lens));
    await tester.pump(const Duration(milliseconds: 600));
    await hold.moveBy(const Offset(26, 0));
    await tester.pump();
    expect(value, isFalse);
    await hold.up();
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('selection keeps its recessed well beneath a moving glass lens', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      app(
        LuminaTheme(
          child: Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, update) => LuminaSegmented<int>(
                  items: const {0: 'First', 1: 'Second', 2: 'Third'},
                  value: selected,
                  onChanged: (value) => update(() => selected = value),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final well = find.byKey(const ValueKey('lumina-selection-well'));
    final lens = find.byKey(const ValueKey('lumina-selection-lens'));
    expect(well, findsOneWidget);
    expect(lens, findsOneWidget);
    final wellOrigin = tester.getTopLeft(well);
    final lensOrigin = tester.getTopLeft(lens);
    await tester.tap(find.text('Third'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(tester.getTopLeft(well), wellOrigin);
    expect(tester.getTopLeft(lens).dx, greaterThan(lensOrigin.dx));
    final hold = await tester.startGesture(tester.getCenter(lens));
    await tester.pump(const Duration(milliseconds: 600));
    await hold.moveBy(const Offset(-200, 0));
    await hold.up();
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('value slider taps and long-press scrubs on the glass well', (
    tester,
  ) async {
    var value = 0.0;
    await tester.pumpWidget(
      app(
        LuminaTheme(
          child: Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, update) => LuminaValueSlider(
                  value: value,
                  divisions: 5,
                  onChanged: (next) => update(() => value = next),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.tapAt(
      tester.getTopLeft(find.byType(LuminaValueSlider)) + const Offset(270, 24),
    );
    await tester.pumpAndSettle();
    expect(value, 1);
    final lens = find.byKey(const ValueKey('lumina-selection-lens'));
    final hold = await tester.startGesture(tester.getCenter(lens));
    await tester.pump(const Duration(milliseconds: 600));
    await hold.moveBy(const Offset(-240, 0));
    await hold.up();
    await tester.pumpAndSettle();
    expect(value, 0);
  });
  tearDown(() {
    LuminaHaptics.confirmHandler = null;
    LuminaCardMemory.store = LuminaMemoryCardStore();
  });

  test(
    'default store and optional failing persistence need no plugins',
    () async {
      LuminaCardMemory.save('demo', false);
      expect(LuminaCardMemory.expanded('demo'), isFalse);
      LuminaCardMemory.store = _FailingStore();
      LuminaCardMemory.save('demo', true);
      await Future<void>.delayed(Duration.zero);
      expect(LuminaCardMemory.expanded('missing'), isTrue);
    },
  );

  test('default haptics use the standard Flutter platform API', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await LuminaHaptics.confirm();
    expect(calls.single.method, 'HapticFeedback.vibrate');
    expect(calls.single.arguments, 'HapticFeedbackType.lightImpact');
  });

  testWidgets('built-in labels follow the registered language', (tester) async {
    for (final language in ['en', 'zh']) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Text(
              LuminaLocalizations.of(context).confirm,
              textDirection: TextDirection.ltr,
            ),
          ),
          locale: Locale(language),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(language == 'en' ? 'Confirm' : '确定'), findsOneWidget);
    }
  });

  testWidgets('palette preserves central theme overrides', (tester) async {
    const data = LuminaThemeData(
      fontScale: 1.5,
      spacingScale: 1.25,
      radiusScale: 1.1,
      motionScale: 0,
    );
    late LuminaTheme theme;
    await tester.pumpWidget(
      app(
        LuminaTheme(
          data: data,
          child: LuminaPalette(
            palette: LuminaCardPalette.sage,
            child: Builder(
              builder: (context) {
                theme = LuminaTheme.of(context);
                expect(LuminaTheme.motionReducedOf(context), isTrue);
                return Center(
                  child: LuminaSurface(
                    child: const SizedBox(width: 10, height: 10),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(theme.data, same(data));
    expect(theme.textTheme.cardTitle.fontSize, 27);
    expect(theme.colors.tint, LuminaCardPalette.sage.tint);
    expect(tester.getSize(find.byType(LuminaSurface)), const Size(50, 50));
    expect(tester.takeException(), isNull);
  });
}
