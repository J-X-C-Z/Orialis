import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

Finder _composerField() => find.descendant(
  of: find.byKey(const ValueKey('chat-composer')),
  matching: find.byType(EditableText),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final size in [
    const Size(844, 390),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    testWidgets(
      'chat puts controls left of transcript at $size with keyboard',
      (tester) async {
        final h = await openChat(tester);
        expect(find.byKey(const ValueKey('chat-side-header')), findsNothing);
        expect(find.byType(LuminaTopBar), findsOneWidget);
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final sidebar = find.byKey(const ValueKey('chat-side-header'));
        final viewport = find.byKey(const ValueKey('chat-message-viewport'));
        expect(sidebar, findsOneWidget);
        expect(tester.getSize(sidebar).width, 112);
        expect(tester.getSize(sidebar).height, tester.getSize(viewport).height);
        expect(
          tester.getSize(viewport).width,
          closeTo(
            tester
                    .getSize(
                      find.byKey(const ValueKey('chat-conversation-detail')),
                    )
                    .width -
                112,
            1,
          ),
        );
        final rail = tester.widget<LuminaSurface>(sidebar);
        expect(rail.depth, LuminaSurfaceDepth.raised);
        expect(rail.liquidGlass, isFalse);
        expect(
          find.descendant(
            of: sidebar,
            matching: find.byType(SingleChildScrollView),
          ),
          findsOneWidget,
        );
        expect(
          tester.getRect(sidebar).right,
          lessThanOrEqualTo(tester.getRect(viewport).left),
        );
        expect(
          tester.getRect(sidebar).top,
          closeTo(tester.getRect(viewport).top, 1),
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('chat-composer'))).left,
          greaterThanOrEqualTo(tester.getRect(sidebar).right),
        );
        expect(iconAction('返回会话列表').hitTestable(), findsOneWidget);
        expect(iconAction('更多会话操作').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('chat-desktop-layout')),
          size.width >= 900 ? findsOneWidget : findsNothing,
        );
        await tester.enterText(_composerField(), '旋转后继续编辑');
        tester.view.viewInsets = const FakeViewPadding(bottom: 120);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('chat-composer'))).bottom,
          lessThanOrEqualTo(size.height - 120),
        );
        expect(
          tester.widget<EditableText>(_composerField()).controller.text,
          '旋转后继续编辑',
        );
        expect(h.realtime.attempts, 0);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'rotation retains history controller and draft without resending',
    (tester) async {
      final h = await openChat(tester);
      final seed = () async {
        for (var i = 0; i < 40; i++) {
          await h.repo.applyRemoteMessage({
            'conversationId': h.id,
            'id': 'adaptive-$i',
            'role': 'user',
            'content': '消息 $i：旋转时保持当前会话和历史滚动状态。',
            'createdAt': DateTime.utc(2026, 11, 2, 0, i).toIso8601String(),
            'version': 1,
          });
        }
      }();
      await tester.pumpAndSettle();
      await seed;
      await tester.pumpAndSettle();
      Finder transcript() => find
          .descendant(
            of: find.byWidgetPredicate(
              (w) => w is ListView && w.key == ValueKey(h.id),
            ),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(transcript(), const Offset(0, 400));
      await tester.pumpAndSettle();
      final historyController = tester
          .widget<ListView>(
            find.byWidgetPredicate(
              (w) => w is ListView && w.key == ValueKey(h.id),
            ),
          )
          .controller;
      final controller = tester
          .widget<EditableText>(_composerField())
          .controller;
      await tester.enterText(_composerField(), '未发送的草稿');
      for (final size in [
        const Size(844, 390),
        const Size(1280, 800),
        const Size(800, 1280),
        const Size(432, 960),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final position = tester.state<ScrollableState>(transcript()).position;
        expect(
          tester
              .widget<ListView>(
                find.byWidgetPredicate(
                  (w) => w is ListView && w.key == ValueKey(h.id),
                ),
              )
              .controller,
          same(historyController),
        );
        expect(position.extentAfter, greaterThan(1), reason: size.toString());
        expect(
          tester.widget<EditableText>(_composerField()).controller,
          same(controller),
        );
        expect(controller.text, '未发送的草稿');
        expect(h.realtime.attempts, 0);
        expect(tester.takeException(), isNull);
      }
      final beforeIncoming = tester
          .state<ScrollableState>(transcript())
          .position
          .pixels;
      final incoming = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'adaptive-incoming',
        'role': 'assistant',
        'content': '旋转完成后新到的消息',
        'createdAt': '2026-11-02T01:00:00Z',
        'version': 1,
      });
      await tester.pumpAndSettle();
      await incoming;
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(transcript()).position.pixels,
        closeTo(beforeIncoming, 1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('landscape controls scroll with long title and large text', (
    tester,
  ) async {
    final h = await openChat(tester);
    final conversation = (await tester.runAsync(
      () => h.db.select(h.db.conversations).get(),
    ))!.singleWhere((item) => item.id == h.id);
    final title = List.filled(12, '需要保留的长会话标题').join();
    final rename = h.repo.renameConversation(conversation, title);
    await tester.pumpAndSettle();
    await rename;
    tester.view.physicalSize = const Size(844, 390);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('chat-side-header'));
    expect(sidebar, findsOneWidget);
    await tester.ensureVisible(iconAction('更多会话操作'));
    await tester.pumpAndSettle();
    expect(iconAction('更多会话操作').hitTestable(), findsOneWidget);
    expect(_composerField().hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
