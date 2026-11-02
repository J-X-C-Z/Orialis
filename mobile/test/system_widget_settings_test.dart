import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/system_integration/system_integration_controller.dart';
import 'package:orialis_mobile/pages/profile/system_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _System extends SystemIntegrationController {
  _System(AppDatabase database, this.canPin)
    : super(database: database, config: AppConfig(), supported: true);
  final bool canPin;
  String? pinned;
  @override
  Future<void> start() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<Map<Object?, Object?>?> status() async => {
    'widgetCount': 3,
    'pinWidgetSupported': canPin,
  };
  @override
  Future<bool?> requestPinWidget({String kind = 'today'}) async {
    pinned = kind;
    return true;
  }
}

void main() {
  for (final canPin in [true, false]) {
    testWidgets('widget picker works before login; pin support=$canPin', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final database = AppDatabase(executor: AppDatabase.inMemoryExecutor());
      final system = _System(database, canPin);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await system.dispose();
        await database.close();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            systemIntegrationProvider.overrideWithValue(system),
            desktopModeProvider.overrideWithValue(false),
          ],
          child: WidgetsApp(
            color: const Color(0xfff1f3ec),
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (_, _, _) => const SystemSettingsPage(),
            ),
            builder: (_, child) => LuminaTheme(
              highPerformanceMode: true,
              data: const LuminaThemeData(neumorphic: true),
              child: DefaultTextStyle(
                style: const TextStyle(fontSize: 14),
                child: child!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byWidgetPredicate(
        (widget) =>
            widget is LuminaIconButton && widget.tooltip == '添加月历 4×4 小组件',
      );
      await tester.scrollUntilVisible(button, 450);
      // Keep the target below the page's overlaid header after scroll-to-top.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(system.enabled, false);
      expect(system.identityCompatible, false);
      final control = tester.widget<LuminaIconButton>(button);
      if (canPin) {
        expect(control.onPressed, isNotNull);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(system.pinned, 'month');
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      } else {
        expect(control.onPressed, isNull);
        expect(system.pinned, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
