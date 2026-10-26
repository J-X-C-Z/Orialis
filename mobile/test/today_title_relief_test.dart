import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/today/today_page.dart';

void main() {
  testWidgets(
    'glass title keeps folding and trailing action separate at 2x text',
    (tester) async {
      var taps = 0;
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: LuminaTheme(
                brightness: brightness,
                data: const LuminaThemeData(
                  neumorphic: true,
                  neumorphicGlass: true,
                ),
                child: Center(
                  child: SizedBox(
                    width: 340,
                    child: LuminaSection(
                      title: '现在关注',
                      raised: true,
                      glassTitle: true,
                      trailing: LuminaIconButton(
                        tooltip: '恢复排序',
                        icon: const Icon(Icons.refresh),
                        onPressed: () => taps++,
                      ),
                      child: const Text('卡片内容'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final title = tester.getRect(find.text('现在关注'));
        final relief = tester.getRect(
          find.byKey(const ValueKey('lumina-glass-card-title')),
        );
        expect(relief.contains(title.topLeft), isTrue);
        expect(relief.contains(title.bottomRight), isTrue);
        final titleSurface = find.byKey(
          const ValueKey('lumina-glass-card-title'),
        );
        expect(
          tester.widget<LuminaSurface>(titleSurface).depth,
          LuminaSurfaceDepth.recessed,
        );
        expect(
          find.descendant(
            of: titleSurface,
            matching: find.byType(LuminaGlassWell),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: titleSurface,
            matching: find.byType(LuminaGlassCoat),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byType(LuminaIconButton));
        await tester.pumpAndSettle();
        expect(taps, brightness.index + 1);
        await tester.tap(find.text('现在关注'));
        await tester.pumpAndSettle();
        expect(find.text('卡片内容').hitTestable(), findsNothing);
        await tester.tap(find.text('现在关注'));
        await tester.pumpAndSettle();
        expect(find.text('卡片内容').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('actual Today enables title relief only on mobile routes', (
    tester,
  ) async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      Future<void> show(TargetPlatform platform, bool desktop) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(database),
              desktopModeProvider.overrideWithValue(desktop),
            ],
            child: const MaterialApp(
              home: LuminaTheme(
                brightness: Brightness.light,
                data: LuminaThemeData(neumorphic: true, neumorphicGlass: true),
                child: TodayPage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(TargetPlatform.android, false);
      expect(
        find.byKey(const ValueKey('lumina-glass-card-title')),
        findsWidgets,
      );
      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
        await show(platform, true);
        expect(
          find.byKey(const ValueKey('lumina-glass-card-title')),
          findsNothing,
        );
      }
      await show(TargetPlatform.android, true);
      expect(
        find.byKey(const ValueKey('lumina-glass-card-title')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await database.close();
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
