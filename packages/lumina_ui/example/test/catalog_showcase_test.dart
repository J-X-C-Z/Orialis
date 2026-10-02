import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:lumina_ui_example/catalog_showcase.dart';

Widget showcase({double scale = 1, Locale locale = const Locale('en')}) =>
    MaterialApp(
      locale: locale,
      supportedLocales: LuminaLocalizations.supportedLocales,
      localizationsDelegates: const [
        LuminaLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
          builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true),
                child: LuminaTheme(
                  brightness: Brightness.light,
                  highPerformanceMode: true,
                  child: const Scaffold(
                      body: SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: LuminaCatalogShowcase(),
                  )),
                ),
              )),
    );

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
}

void main() {
  testWidgets(
      'all 28 categories render on narrow screens with large text in both languages',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      await tester.pumpWidget(showcase(scale: 1.6, locale: locale));
      await tester.pump();
      expect(LuminaCatalogShowcase.categories, hasLength(28));
      for (final category in LuminaCatalogShowcase.categories) {
        expect(
            find.byKey(ValueKey('catalog-category-$category')), findsOneWidget);
      }
      expect(tester.takeException(), isNull,
          reason: '${locale.languageCode} narrow layout');
    }
  });

  testWidgets(
      'selection, shared navigation, text and discrete slider update state',
      (tester) async {
    await tester.pumpWidget(showcase());
    final checkbox = find.byKey(const ValueKey('catalog-check'));
    await reveal(tester, checkbox);
    await tester.tap(checkbox);
    await tester.pump();
    expect(find.text('Checked'), findsOneWidget);

    final chip = find.byKey(const ValueKey('catalog-chip'));
    await reveal(tester, chip);
    await tester.tap(chip);
    await tester.pump();
    expect(tester.widget<LuminaChip>(chip).selected, isFalse);

    final toggle = find.byKey(const ValueKey('catalog-switch'));
    await reveal(tester, toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('Off'), findsOneWidget);

    final radio = find.byKey(const ValueKey('catalog-radio-1'));
    await reveal(tester, radio);
    await tester.tap(radio);
    await tester.pump();
    expect(tester.widget<LuminaRadio<int>>(radio).groupValue, 1);

    final bar = find.byType(LuminaNavigationBar);
    await reveal(tester, bar);
    await tester.tap(find.descendant(of: bar, matching: find.text('Files')));
    await tester.pump();
    expect(find.text('Current destination: Files'), findsOneWidget);
    expect(
        tester
            .widget<LuminaNavigationDrawer>(find.byType(LuminaNavigationDrawer))
            .selectedIndex,
        1);
    expect(
        tester
            .widget<LuminaNavigationRail>(find.byType(LuminaNavigationRail))
            .selectedIndex,
        1);

    final slider = find.byKey(const ValueKey('catalog-discrete'));
    await reveal(tester, slider);
    final rectangle = tester.getRect(slider);
    await tester.tapAt(
        Offset(rectangle.left + rectangle.width * .8, rectangle.center.dy));
    await tester.pump();
    expect(find.text('Value: 80%'), findsOneWidget);
    expect(
        tester
            .widget<LuminaContinuousSlider>(
                find.byKey(const ValueKey('catalog-continuous')))
            .value,
        .8);

    final input = find.byKey(const ValueKey('catalog-input'));
    await reveal(tester, input);
    await tester.enterText(
        find.descendant(of: input, matching: find.byType(EditableText)),
        'A note');
    await tester.pump();
    expect(find.text('6/80 characters'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog, sheet, menu and pickers complete real interactions',
      (tester) async {
    await tester.pumpWidget(showcase());
    final dialog = find.byKey(const ValueKey('catalog-dialog'));
    await reveal(tester, dialog);
    await tester.tap(dialog);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('catalog-confirm')));
    await tester.pump();
    expect(find.text('Change kept.'), findsOneWidget);

    final sheet = find.byKey(const ValueKey('catalog-sheet'));
    await reveal(tester, sheet);
    await tester.tap(sheet);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('catalog-close-sheet')));
    await tester.pump();
    expect(find.text('A collection of small ideas'), findsNothing);

    final date = find.byKey(const ValueKey('catalog-date'));
    await reveal(tester, date);
    await tester.tap(date);
    await tester.pump();
    await tester.tap(find.text('3').last);
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Date: 2026/10/3'), findsOneWidget);

    final time = find.byKey(const ValueKey('catalog-time'));
    await reveal(tester, time);
    await tester.tap(time);
    await tester.pump();
    final plus = find
        .descendant(
            of: find.byType(LuminaDialog),
            matching: find.byType(LuminaIconButton))
        .first;
    await tester.tap(plus);
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Time: 10:30'), findsOneWidget);
    final menu = find.byKey(const ValueKey('catalog-menu'));
    await reveal(tester, menu);
    await tester.tap(menu);
    await tester.pump();
    await tester.tap(find.text('Duplicate note'));
    await tester.pumpAndSettle();
    expect(find.text('Note duplicated.'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
