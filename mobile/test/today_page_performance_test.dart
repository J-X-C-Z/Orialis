import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold;
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/pages/today/today_page.dart';

void main() {
  testWidgets(
    'today clock runs only while the page is visible and foreground',
    (tester) async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      var visible = true;
      late StateSetter update;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(database)],
          child: MaterialApp(
            home: LuminaTheme(
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return TickerMode(enabled: visible, child: const TodayPage());
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final page = find.byType(OrialisPageScaffold);
      Widget currentPage() => tester.widget(page);
      final initial = currentPage();
      await tester.pump(const Duration(minutes: 1));
      expect(identical(currentPage(), initial), isFalse);

      update(() => visible = false);
      await tester.pumpAndSettle();
      final hidden = currentPage();
      await tester.pump(const Duration(minutes: 3));
      expect(identical(currentPage(), hidden), isTrue);

      update(() => visible = true);
      await tester.pumpAndSettle();
      final restored = currentPage();
      expect(identical(restored, hidden), isFalse);
      await tester.pump(const Duration(minutes: 1));
      expect(identical(currentPage(), restored), isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      final background = currentPage();
      await tester.pump(const Duration(minutes: 3));
      expect(identical(currentPage(), background), isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final resumed = currentPage();
      expect(identical(resumed, background), isFalse);
      await tester.pump(const Duration(minutes: 1));
      expect(identical(currentPage(), resumed), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await database.close();
    },
  );
}
