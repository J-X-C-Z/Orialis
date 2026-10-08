import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orialis_mobile/features/projects/data/project_repository.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/features/events/data/event_repository.dart';
import 'lumina_chat_flow_test.dart' show openChat, iconAction;

void main() {
  testWidgets(
    'long press reorders adjacent tasks and empty quadrant accepts move with undo',
    (tester) async {
      final h = await openChat(tester);
      final repo = EventRepository(database: h.db, config: AppConfig());
      final seed = () async {
        await repo.createTask(title: '排序甲', important: true, urgent: true);
        await repo.createTask(title: '排序乙', important: true, urgent: true);
      }();
      await tester.pumpAndSettle();
      await seed;
      await tester.pumpAndSettle();
      await tester.tap(iconAction('返回会话列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('事件').last);
      await tester.pumpAndSettle();
      Future<void> drag(Finder source, Finder target) async {
        final end = tester.getCenter(target);
        final gesture = await tester.startGesture(tester.getCenter(source));
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(end);
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await drag(find.text('排序甲'), find.text('排序乙'));
      final ordered =
          (await tester.runAsync(() => h.db.select(h.db.tasks).get()))!..sort(
            (a, b) =>
                (a.manualPosition ?? 99).compareTo(b.manualPosition ?? 99),
          );
      expect(ordered.map((t) => t.title), ['排序乙', '排序甲']);
      await drag(find.text('排序甲'), find.text('紧急但不重要'));
      final moved = (await tester.runAsync(
        () => h.db.select(h.db.tasks).get(),
      ))!.singleWhere((t) => t.title == '排序甲');
      expect(moved.important, isFalse);
      expect(moved.urgent, isTrue);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      final undone = (await tester.runAsync(
        () => h.db.select(h.db.tasks).get(),
      ))!.singleWhere((t) => t.title == '排序甲');
      expect(undone.important, isTrue);
      expect(undone.urgent, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'project detail back collapses before returning to its source page',
    (tester) async {
      final h = await openChat(tester);
      final pending = ProjectRepository(h.db).createProject(name: '返回测试项目');
      await tester.pumpAndSettle();
      await pending;
      await tester.tap(iconAction('返回会话列表'));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.text('离线会话'))).push('/projects');
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回测试项目'));
      await tester.pumpAndSettle();
      expect(find.text('里程碑'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('里程碑'), findsNothing);
      expect(find.text('返回测试项目'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('离线会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
