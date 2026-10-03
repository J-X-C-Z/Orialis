import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget host(Widget child, Brightness brightness, bool liquid) => m.MaterialApp(
  home: LuminaTheme(
    brightness: brightness,
    highPerformanceMode: true,
    data: LuminaThemeData(liquidGlass: liquid),
    child: MediaQuery(
      data: const MediaQueryData(size: Size(800, 600), disableAnimations: true),
      child: m.Scaffold(body: child),
    ),
  ),
);

List<dynamic> materials(WidgetTester tester, [Finder? within]) => tester
    .widgetList<CustomPaint>(
      within == null
          ? find.byType(CustomPaint)
          : find.descendant(of: within, matching: find.byType(CustomPaint)),
    )
    .map((widget) => widget.painter)
    .where((p) => p.runtimeType.toString() == '_LuminaMaterial')
    .cast<dynamic>()
    .toList();

void expectCards(List<dynamic> paints) {
  expect(paints, isNotEmpty);
  for (final paint in paints) {
    expect(paint.glass, isFalse);
    expect(paint.liquidGlass, isFalse);
    expect(paint.tint.a, 1);
  }
}

void main() {
  testWidgets('opaque selected surface leaves its label visible', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      host(
        Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 320,
              child: LuminaSegmented<String>(
                items: const {'daily': 'Daily', 'weekly': 'Weekly'},
                value: 'daily',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
        Brightness.light,
        false,
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var inkPixels = 0;
      for (var y = 20; y < image.height - 20; y++) {
        for (var x = 35; x < 125; x++) {
          final i = (y * image.width + x) * 4;
          if (bytes.getUint8(i) < 90 &&
              bytes.getUint8(i + 1) < 90 &&
              bytes.getUint8(i + 2) < 90) {
            inkPixels++;
          }
        }
      }
      image.dispose();
      expect(inkPixels, greaterThan(20));
    });
  });

  for (final brightness in Brightness.values) {
    for (final liquid in [false, true]) {
      testWidgets(
        'sheet buttons are cards, page buttons retain glass: $brightness/$liquid',
        (tester) async {
          Widget buttons() => Wrap(
            children: [
              LuminaButton(onPressed: () {}, child: const Text('Primary')),
              const LuminaButton(onPressed: null, child: Text('Disabled')),
              LuminaButton(
                primary: false,
                onPressed: () {},
                child: const Text('Secondary'),
              ),
              LuminaIconButton(onPressed: () {}, icon: const Text('Icon')),
              const LuminaIconButton(
                onPressed: null,
                icon: Text('Disabled icon'),
              ),
              LuminaFloatingActionButton(
                onPressed: () {},
                icon: const Text('FAB'),
              ),
              for (final variant in LuminaButtonVariant.values)
                LuminaMaterialButton(
                  variant: variant,
                  onPressed: () {},
                  child: Text(variant.name),
                ),
            ],
          );
          await tester.pumpWidget(
            host(
              Builder(
                builder: (context) => Column(
                  children: [
                    buttons(),
                    GestureDetector(
                      onTap: () => showLuminaSheet<void>(
                        context: context,
                        builder: (_) => buttons(),
                      ),
                      child: const Text('Open sheet'),
                    ),
                  ],
                ),
              ),
              brightness,
              liquid,
            ),
          );
          await tester.pumpAndSettle();
          final normal = materials(tester);
          expect(normal.length, greaterThanOrEqualTo(10));
          expect(
            normal.every((p) => p.glass == true && p.liquidGlass == liquid),
            isTrue,
          );
          await tester.tap(find.text('Open sheet'));
          await tester.pumpAndSettle();
          final scope = find.byType(LuminaCardScope);
          expectCards(materials(tester, scope));
          expect(materials(tester, scope).length, normal.length);
          expect(
            find.descendant(of: scope, matching: find.byType(BackdropFilter)),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'top tabs shell and selection are cards: $brightness/$liquid',
        (tester) async {
          final controller = m.TabController(length: 2, vsync: tester);
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            host(
              LuminaTabs(
                controller: controller,
                tabs: const [Text('First tab'), Text('Second tab')],
              ),
              brightness,
              liquid,
            ),
          );
          await tester.pumpAndSettle();
          expectCards(materials(tester));
          await tester.tap(find.text('Second tab'));
          await tester.pumpAndSettle();
          expect(controller.index, 1);
          expectCards(materials(tester));
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'segmented cards and calendar transparent opt-in: $brightness/$liquid',
        (tester) async {
          for (final transparent in [false, true]) {
            var selected = 0;
            await tester.pumpWidget(
              host(
                m.StatefulBuilder(
                  builder: (context, update) => LuminaSegmented<int>(
                    transparent: transparent,
                    items: const {0: 'Day', 1: 'Week', 2: 'Month'},
                    value: selected,
                    onChanged: (value) => update(() => selected = value),
                  ),
                ),
                brightness,
                liquid,
              ),
            );
            await tester.pumpAndSettle();
            if (!transparent) {
              expectCards(materials(tester));
              expect(find.byType(BackdropFilter), findsNothing);
            } else {
              for (final key in [
                'lumina-selection-well',
                'lumina-selection-lens',
              ]) {
                final dynamic paint = tester
                    .widget<CustomPaint>(find.byKey(ValueKey(key)))
                    .painter;
                expect(paint.glass, isTrue);
                expect(paint.liquidGlass, liquid);
                expect(paint.tint.a, lessThan(1));
              }
            }
            await tester.tap(find.text('Month'));
            await tester.pumpAndSettle();
            expect(selected, 2);
            if (!transparent) expectCards(materials(tester));
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          }
        },
      );
    }
  }
}
