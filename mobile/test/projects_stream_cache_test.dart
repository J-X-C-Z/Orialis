import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show LuminaCardMemory;
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';
import 'package:orialis_mobile/pages/projects/projects_page.dart';

class _CountingProjectRepository extends ProjectRepository {
  _CountingProjectRepository(super.database);

  int projectWatches = 0;
  int milestoneWatches = 0;
  int taskWatches = 0;

  @override
  Stream<List<Project>> watchProjects() {
    projectWatches++;
    return super.watchProjects();
  }

  @override
  Stream<List<ProjectMilestone>> watchMilestones(String projectId) {
    milestoneWatches++;
    return super.watchMilestones(projectId);
  }

  @override
  Stream<List<Task>> watchProjectTasks(String projectId) {
    taskWatches++;
    return super.watchProjectTasks(projectId);
  }
}

void main() {
  testWidgets('project page reuses streams across selection rebuilds', (
    tester,
  ) async {
    LuminaCardMemory.selectProject(null);
    final database = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(database.close);
    final repository = _CountingProjectRepository(database);
    final project = await repository.createProject(name: '测试项目');
    await repository.createMilestone(projectId: project.id, title: '第一步');
    final nextDatabase = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(nextDatabase.close);
    final nextRepository = _CountingProjectRepository(nextDatabase);
    await nextRepository.createProject(name: '另一个账号项目');
    var activeRepository = repository;
    final container = ProviderContainer(
      overrides: [
        projectRepositoryProvider.overrideWith((ref) => activeRepository),
        desktopModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const ProjectsPage(embedded: true),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: WidgetsApp.router(
          color: const Color(0xFFFFFFFF),
          routerConfig: router,
          builder: (_, child) => LuminaTheme(child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.projectWatches, 1);
    expect(repository.milestoneWatches, 1);

    await tester.tap(find.text('测试项目'));
    await tester.pumpAndSettle();
    expect(repository.projectWatches, 1);
    expect(repository.milestoneWatches, 1);
    expect(repository.taskWatches, 1);
    expect(tester.takeException(), isNull);

    activeRepository = nextRepository;
    container.invalidate(projectRepositoryProvider);
    await tester.pumpAndSettle();
    expect(find.text('另一个账号项目'), findsOneWidget);
    expect(repository.projectWatches, 1);
    expect(nextRepository.projectWatches, 1);
    expect(nextRepository.milestoneWatches, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
