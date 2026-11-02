import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/app.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';
import 'package:orialis_mobile/pages/events/events_page.dart';
import 'package:orialis_mobile/pages/projects/projects_page.dart';

class _Config extends AppConfig {
  @override
  Future<String> deviceId() async => 'project-properties-ui-test';
}

Future<void> _showPage(
  WidgetTester tester,
  AppDatabase database,
  Widget page,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => page)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appConfigProvider.overrideWithValue(_Config()),
        desktopModeProvider.overrideWithValue(false),
      ],
      child: WidgetsApp.router(
        color: const Color(0xFFE9EEF4),
        routerConfig: router,
        builder: (context, child) => LuminaTheme(
          highPerformanceMode: true,
          data: const LuminaThemeData(neumorphic: true, neumorphicGlass: true),
          child: DefaultTextStyle(
            style: const LuminaTextTheme(LuminaColors(dark: false)).bodyMedium,
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('completed milestones fold automatically and can be reopened', (
    tester,
  ) async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ProjectRepository(database);
    final project = await repository.createProject(name: '里程碑折叠');
    final pending = await repository.createMilestone(
      projectId: project.id,
      title: '准备初稿',
    );
    await repository.createMilestone(projectId: project.id, title: '确认定稿');
    final completed = await repository.createMilestone(
      projectId: project.id,
      title: '收集资料',
    );
    await repository.completeMilestone(completed, true);
    await _showPage(tester, database, const ProjectsPage(embedded: true));
    await _tap(tester, find.text('里程碑折叠'));
    expect(find.text('准备初稿'), findsOneWidget);
    expect(find.text('收集资料'), findsNothing);
    final toggle = find.byKey(const ValueKey('completed-milestones-toggle'));
    expect(find.text('已完成 · 1'), findsOneWidget);
    await _tap(tester, toggle);
    expect(find.text('收集资料'), findsOneWidget);
    await _tap(
      tester,
      find.descendant(
        of: find.byKey(ValueKey(pending.id)),
        matching: find.byType(LuminaCheck),
      ),
    );
    expect(find.text('已完成 · 2'), findsOneWidget);
    expect(find.text('准备初稿'), findsNothing);
    expect(find.text('收集资料'), findsNothing);
    expect(find.text('确认定稿'), findsOneWidget);
    await _tap(tester, toggle);
    expect(find.text('准备初稿'), findsOneWidget);
    await _tap(
      tester,
      find.descendant(
        of: find.byKey(ValueKey(pending.id)),
        matching: find.byType(LuminaCheck),
      ),
    );
    expect(find.text('已完成 · 1'), findsOneWidget);
    expect(find.text('准备初稿'), findsOneWidget);
    final stored = await database.select(database.projectMilestones).get();
    expect(stored, hasLength(3));
    expect(stored.singleWhere((m) => m.id == pending.id).completed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('project status selector filters and taps off back to all', (
    tester,
  ) async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ProjectRepository(database);
    await repository.createProject(
      name: '尚未开始',
      category: 'course',
      status: 'not_started',
    );
    await repository.createProject(
      name: '正在推进',
      category: 'work',
      status: 'active',
    );
    await repository.createProject(
      name: '已经完成',
      category: 'life',
      status: 'completed',
    );
    await repository.createProject(
      name: '旧归档仍可访问',
      category: 'general',
      status: 'archived',
    );
    await _showPage(tester, database, const EventsPage());

    final header = find.byKey(const ValueKey('events-compact-header'));
    final modeSelector = find.byKey(const ValueKey('events-mode-selector'));
    final taskFilter = find.byKey(const ValueKey('events-filter-selector'));
    expect(
      tester.getSize(modeSelector).width / tester.getSize(taskFilter).width,
      closeTo(2 / 3, .04),
    );
    expect(
      tester.getRect(taskFilter).right,
      closeTo(tester.getRect(header).right, .1),
    );
    await _tap(
      tester,
      find.descendant(of: modeSelector, matching: find.text('项目')),
    );

    expect(find.text('尚未开始'), findsOneWidget);
    expect(find.text('正在推进'), findsOneWidget);
    expect(find.text('已经完成'), findsOneWidget);
    final projectScroll = find
        .descendant(
          of: find.byType(ProjectsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('旧归档仍可访问'),
      150,
      scrollable: projectScroll,
    );
    expect(find.text('旧归档仍可访问'), findsOneWidget);

    final statusFilter = find.byKey(
      const ValueKey('events-project-status-filter'),
    );
    await _tap(
      tester,
      find.descendant(of: statusFilter, matching: find.text('进行中')),
    );
    expect(find.text('正在推进'), findsOneWidget);
    expect(find.text('尚未开始'), findsNothing);
    expect(find.text('已经完成'), findsNothing);
    expect(find.text('旧归档仍可访问'), findsNothing);

    await _tap(
      tester,
      find.descendant(of: statusFilter, matching: find.text('进行中')),
    );
    expect(find.text('尚未开始'), findsOneWidget);
    expect(find.text('正在推进'), findsOneWidget);
    expect(find.text('已经完成'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('旧归档仍可访问'),
      150,
      scrollable: projectScroll,
    );
    expect(find.text('旧归档仍可访问'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('project editor saves category and status and clears dates', (
    tester,
  ) async {
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ProjectRepository(database);
    final project = await repository.createProject(
      name: '属性项目',
      category: 'general',
      status: 'active',
      description: '需要清空的描述',
      startDate: '2026-01-01',
      due: '2026-02-01',
    );
    await _showPage(tester, database, const ProjectsPage(embedded: true));

    await _tap(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is LuminaIconButton && widget.tooltip == '管理 属性项目',
      ),
    );
    await _tap(tester, find.text('编辑'));

    final category = find.byKey(const ValueKey('project-editor-category'));
    await _tap(tester, category);
    expect(find.text('选择分类'), findsOneWidget);
    await _tap(tester, find.text('工作').first);

    final status = find.byKey(const ValueKey('project-editor-status'));
    await _tap(tester, find.descendant(of: status, matching: find.text('已完成')));
    await _tap(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is LuminaIconButton && widget.tooltip == '清除开始日期',
      ),
    );

    final description = find.descendant(
      of: find.byKey(const ValueKey('project-editor-description')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(description, '');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('project-editor-save')));

    final stored = await (database.select(
      database.projects,
    )..where((row) => row.id.equals(project.id))).getSingle();
    expect(stored.category, 'work');
    expect(stored.status, 'completed');
    expect(stored.description, isNull);
    expect(stored.startDate, isNull);
    expect(stored.due, '2026-02-01');
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
