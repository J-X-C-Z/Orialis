import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/pages/shell/orialis_shell.dart';

void main() {
  testWidgets(
    'shell consumes keyboard inset exactly once and hides navigation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      var childInset = -1.0;
      final router = GoRouter(
        initialLocation: '/page0',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => OrialisShell(navigationShell: shell),
            branches: List.generate(
              5,
              (index) => StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/page$index',
                    builder: (context, _) {
                      childInset = MediaQuery.viewInsetsOf(context).bottom;
                      return const SizedBox.expand(
                        key: ValueKey('page-bounds'),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        WidgetsApp.router(
          color: const Color(0xFFFFFFFF),
          routerConfig: router,
          builder: (_, child) => LuminaTheme(child: child!),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester
          .getSize(find.byKey(const ValueKey('page-bounds')))
          .height;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('page-bounds'))).height,
        before - 300,
      );
      expect(childInset, 0);
      expect(find.text('今日'), findsNothing);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('page-bounds'))).height,
        before,
      );
      expect(find.text('今日'), findsOneWidget);
    },
  );
}
