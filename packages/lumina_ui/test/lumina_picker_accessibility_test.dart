import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() {
  testWidgets(
    'dialog and sheet builders receive the active inherited environment',
    (tester) async {
      LuminaTheme? observedTheme;
      MediaQueryData? observedMedia;
      await tester.pumpWidget(
        m.MaterialApp(
          home: m.Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.8),
                disableAnimations: true,
              ),
              child: LuminaTheme(
                brightness: Brightness.dark,
                data: const LuminaThemeData(liquidGlass: true),
                child: m.Builder(
                  builder: (context) => Column(
                    children: [
                      LuminaButton(
                        child: const Text('Dialog'),
                        onPressed: () => showLuminaDialog(
                          context: context,
                          builder: (overlayContext) {
                            observedTheme = LuminaTheme.of(overlayContext);
                            observedMedia = MediaQuery.of(overlayContext);
                            return const LuminaDialog(
                              title: 'Overlay',
                              content: Text('Content'),
                            );
                          },
                        ),
                      ),
                      LuminaButton(
                        child: const Text('Sheet'),
                        onPressed: () => showLuminaSheet(
                          context: context,
                          builder: (overlayContext) {
                            observedTheme = LuminaTheme.of(overlayContext);
                            observedMedia = MediaQuery.of(overlayContext);
                            return const Text('Sheet content');
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final label in ['Dialog', 'Sheet']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(observedTheme!.brightness, Brightness.dark);
        expect(observedTheme!.data.liquidGlass, isTrue);
        expect(observedMedia!.textScaler.scale(10), 18);
        expect(observedMedia!.disableAnimations, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('transient feedback inherits dark palette and glass preference', (
    tester,
  ) async {
    await tester.pumpWidget(
      m.MaterialApp(
        home: LuminaTheme(
          brightness: Brightness.dark,
          data: const LuminaThemeData(liquidGlass: true),
          tint: LuminaCardPalette.ocean.tint,
          reduceTransparency: true,
          child: m.Builder(
            builder: (context) => LuminaButton(
              child: const Text('Notify'),
              onPressed: () => showLuminaMessage(context, 'Saved'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Notify'));
    await tester.pump();
    final theme = LuminaTheme.of(tester.element(find.text('Saved')));
    expect(theme.brightness, Brightness.dark);
    expect(theme.tint, LuminaCardPalette.ocean.tint);
    expect(theme.data.liquidGlass, isTrue);
    expect(theme.reduceTransparency, isTrue);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('calendar stays usable in a narrow dialog at double text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: LuminaTheme(
              child: m.Builder(
                builder: (context) => LuminaButton(
                  child: const Text('Date'),
                  onPressed: () => showLuminaDatePicker(
                    context: context,
                    initialDate: DateTime(2026, 10, 15),
                    firstDate: DateTime(2026),
                    lastDate: DateTime(2027),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Date'));
    await tester.pumpAndSettle();
    expect(find.text('15'), findsOneWidget);
    expect(
      MediaQuery.textScalerOf(tester.element(find.text('15'))).scale(10),
      20,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'calendar limits months, normalizes days and responds to arrows',
    (tester) async {
      DateTime? result;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        m.MaterialApp(
          home: LuminaTheme(
            child: m.Builder(
              builder: (context) => LuminaButton(
                child: const Text('Open date'),
                onPressed: () async => result = await showLuminaDatePicker(
                  context: context,
                  initialDate: DateTime(2026, 10, 15, 16),
                  firstDate: DateTime(2026, 10, 14, 23),
                  lastDate: DateTime(2026, 10, 16, 1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open date'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LuminaIconButton>(
              find.byWidgetPredicate(
                (w) => w is LuminaIconButton && w.tooltip == '上个月',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<LuminaIconButton>(
              find.byWidgetPredicate(
                (w) => w is LuminaIconButton && w.tooltip == '下个月',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(find.bySemanticsLabel('2026-10-15'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, DateTime(2026, 10, 16));
      semantics.dispose();
    },
  );

  testWidgets('time adjustment controls describe units and wrap at midnight', (
    tester,
  ) async {
    DateTime? result;
    await tester.pumpWidget(
      m.MaterialApp(
        home: LuminaTheme(
          child: m.Builder(
            builder: (context) => LuminaButton(
              child: const Text('Open time'),
              onPressed: () async => result = await showLuminaTimePicker(
                context: context,
                initialTime: DateTime(2026, 10, 2, 23, 59),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open time'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is LuminaIconButton && w.tooltip == '增加小时',
      ),
    );
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is LuminaIconButton && w.tooltip == '增加分钟',
      ),
    );
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, DateTime(2026, 10, 2));
  });
}
