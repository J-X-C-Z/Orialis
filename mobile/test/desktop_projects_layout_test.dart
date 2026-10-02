import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';
import 'package:orialis_mobile/pages/projects/projects_page.dart';

Future<void> _showProjects(
  WidgetTester tester,
  AppDatabase database, {
  bool desktop = true,
}) async {
  tester.view.physicalSize = const Size(1180, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ProjectsPage(embedded: true)),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        desktopModeProvider.overrideWithValue(desktop),
      ],
      child: WidgetsApp.router(
        color: const Color(0xFFFFFFFF),
        routerConfig: router,
        builder: (_, child) => LuminaTheme(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'desktop project selection keeps list beside working milestones',
    (tester) async {
      final database = AppDatabase(executor: NativeDatabase.memory());
      final repository = ProjectRepository(database);
      final first = await repository.createProject(name: '出版手册', goal: '完成初版');
      final second = await repository.createProject(name: '秋季旅行', goal: '整理路线');
      await repository.createMilestone(projectId: first.id, title: '完成目录');
      await repository.createMilestone(projectId: second.id, title: '安排车票');
      await _showProjects(tester, database);

      expect(find.text('选择一个项目'), findsOneWidget);
      final firstRow = find.byKey(ValueKey('desktop-project:${first.id}'));
      final secondRow = find.byKey(ValueKey('desktop-project:${second.id}'));
      await tester.tap(firstRow);
      await tester.pumpAndSettle();
      expect(find.text('完成目录'), findsOneWidget);
      expect(secondRow, findsOneWidget);
      expect(
        tester.getRect(firstRow).right,
        lessThan(
          tester
              .getRect(find.byKey(const ValueKey('desktop-project-detail')))
              .left,
        ),
      );
      await tester.tap(find.byType(LuminaCheck).first);
      await tester.pumpAndSettle();
      expect(
        (await database.select(database.projectMilestones).get())
            .first
            .completed,
        isTrue,
      );

      await tester.tap(secondRow);
      await tester.pumpAndSettle();
      expect(find.text('安排车票'), findsOneWidget);
      expect(find.text('完成目录'), findsNothing);
      expect(firstRow, findsOneWidget);
      expect(tester.takeException(), isNull);

      // Resizing retains the selected project in the existing mobile card flow.
      tester.view.physicalSize = const Size(600, 800);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-projects-workspace')),
        findsNothing,
      );
      final selectedCard = tester
          .widgetList<LuminaExpandableCard>(find.byType(LuminaExpandableCard))
          .where((card) => card.expanded);
      expect(selectedCard, hasLength(1));
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(1180, 800);
      await tester.pumpAndSettle();
      expect(find.text('安排车票'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await database.close();
    },
  );

  testWidgets('wide mobile still uses expandable project cards', (
    tester,
  ) async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    await ProjectRepository(database).createProject(name: '手机项目');
    await _showProjects(tester, database, desktop: false);
    expect(find.byType(LuminaExpandableCard), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktop-projects-workspace')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await database.close();
  });
}
