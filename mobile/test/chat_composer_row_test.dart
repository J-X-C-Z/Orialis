import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

final _composer = find.byKey(const ValueKey('chat-composer'));
Finder _field() =>
    find.descendant(of: _composer, matching: find.byType(LuminaTextField));
Finder _editor() =>
    find.descendant(of: _field(), matching: find.byType(EditableText));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'ordinary composer keeps add input and send on one row without device label',
    (tester) async {
      final h = await openChat(tester);
      final surface = tester.widget<LuminaSurface>(_composer);
      expect(surface.radius, 28);
      expect(surface.depth, LuminaSurfaceDepth.raised);
      expect(surface.glass || surface.frosted || surface.backdrop, isFalse);
      expect(surface.liquidGlass, isFalse);
      expect(
        find.descendant(of: _composer, matching: find.text('Hermes')),
        findsNothing,
      );
      final add = tester.getRect(iconAction('附件与快捷指令'));
      final field = tester.getRect(_field());
      final send = tester.getRect(iconAction('发送'));
      expect(add.right, lessThanOrEqualTo(field.left));
      expect(field.right, lessThanOrEqualTo(send.left));
      expect(add.center.dy, closeTo(field.center.dy, 1));
      expect(send.center.dy, closeTo(field.center.dy, 1));
      await tester.enterText(_editor(), '第一行\n第二行\n第三行');
      await tester.pumpAndSettle();
      expect(
        tester.getSize(_composer).height,
        greaterThan(surface.padding.vertical + field.height),
      );
      tester.testTextInput.hide();
      await tester.tap(_editor());
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(
        tester.widget<EditableText>(_editor()).controller.text,
        '第一行\n第二行\n第三行',
      );
      expect(h.realtime.attempts, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'messages reach the screen edge while composer clears gestures and keyboard',
    (tester) async {
      final h = await openChat(tester);
      const gestureInset = 32.0;
      tester.view.padding = const FakeViewPadding(bottom: gestureInset);
      tester.view.viewPadding = const FakeViewPadding(bottom: gestureInset);
      tester.view.systemGestureInsets = const FakeViewPadding(
        bottom: gestureInset,
      );
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetSystemGestureInsets);
      addTearDown(tester.view.resetViewInsets);
      final seed = () async {
        for (var i = 0; i < 45; i++) {
          await h.repo.applyRemoteMessage({
            'conversationId': h.id,
            'id': 'inline-$i',
            'role': 'user',
            'content': '信息流 $i：验证消息可以在底部输入区周围滑过。',
            'createdAt': DateTime.utc(2026, 11, 2, 0, i).toIso8601String(),
            'version': 1,
          });
        }
      }();
      await tester.pumpAndSettle();
      await seed;
      await tester.pumpAndSettle();
      final viewport = find.byKey(const ValueKey('chat-message-viewport'));
      final screenBottom =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(tester.getRect(viewport).bottom, closeTo(screenBottom, .1));
      expect(
        tester.getRect(viewport).bottom - tester.getRect(_composer).bottom,
        closeTo(gestureInset + 12, .1),
      );
      final transcript = find
          .descendant(
            of: find.byWidgetPredicate(
              (w) => w is ListView && w.key == ValueKey(h.id),
            ),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(transcript).position;
      expect(position.extentAfter, lessThan(1));
      expect(
        tester.getRect(find.byKey(const ValueKey('inline-44'))).bottom,
        lessThanOrEqualTo(tester.getRect(_composer).top),
      );
      await tester.drag(transcript, const Offset(0, 450));
      await tester.pumpAndSettle();
      final before = position.pixels;
      await tester.dragFrom(
        Offset(4, screenBottom - 16),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(before + 40));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.view.padding = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(tester.getRect(viewport).bottom, closeTo(screenBottom - 280, .1));
      expect(
        tester.getRect(viewport).bottom - tester.getRect(_composer).bottom,
        closeTo(12, .1),
      );
      expect(h.realtime.attempts, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'reply preview stays above inline input and attachment menu keeps the draft',
    (tester) async {
      final h = await openChat(tester);
      final write = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': 'inline-reply',
        'role': 'assistant',
        'content': '需要回复的消息',
        'createdAt': '2026-11-02T00:00:00Z',
        'version': 1,
      });
      await tester.pumpAndSettle();
      await write;
      await tester.pumpAndSettle();
      await tester.drag(
        find.text('需要回复的消息', findRichText: true).first,
        const Offset(90, 0),
      );
      await tester.pumpAndSettle();
      final quote = find.byType(LuminaQuotePreview);
      expect(find.text('回复 Hermes'), findsOneWidget);
      expect(
        tester.getRect(quote).bottom,
        lessThanOrEqualTo(tester.getRect(_field()).top),
      );
      await tester.enterText(_editor(), '保留的回复草稿');
      await tester.tap(iconAction('附件与快捷指令'));
      await tester.pumpAndSettle();
      expect(find.text('选择文件'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(_editor()).controller.text, '保留的回复草稿');
      expect(quote, findsOneWidget);
      expect(h.realtime.attempts, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
