import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:shared_preferences/shared_preferences.dart';

import 'lumina_chat_flow_test.dart' show openChat, iconAction;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final size in [
    const Size(432, 960),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('search and filter share a material card at $size', (
      tester,
    ) async {
      final h = await openChat(tester);
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      if (size.width < 900) {
        await tester.tap(iconAction('返回会话列表'));
        await tester.pumpAndSettle();
      }
      final card = find.byKey(const ValueKey('conversation-controls-card'));
      final search = find.byKey(const ValueKey('conversation-search'));
      final filters = find.byKey(const ValueKey('conversation-filters'));
      expect(
        tester.widget<LuminaTextField>(search).radius,
        LuminaControlSize.capsuleRadius,
      );
      final material = tester.widget<LuminaSurface>(
        find.descendant(of: card, matching: find.byType(LuminaSurface)).first,
      );
      expect(material.depth, LuminaSurfaceDepth.raised);
      expect(material.liquidGlass, isFalse);
      expect(material.glass, isFalse);
      expect(material.padding, const EdgeInsets.all(6));
      expect(LuminaCardHost.of(tester.element(search)), isTrue);
      expect(find.descendant(of: card, matching: search), findsOneWidget);
      expect(find.descendant(of: card, matching: filters), findsOneWidget);
      expect(
        tester.getRect(search).left,
        greaterThanOrEqualTo(tester.getRect(card).left + 6),
      );
      expect(
        tester.getRect(filters).right,
        lessThanOrEqualTo(tester.getRect(card).right - 6),
      );
      final editor = find.descendant(
        of: search,
        matching: find.byType(EditableText),
      );
      final controller = tester.widget<EditableText>(editor).controller;
      await tester.enterText(editor, '不存在的会话');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的会话，试试其他搜索或筛选。'), findsOneWidget);
      expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
      await tester.enterText(editor, '');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('conversation-row-${h.id}')), findsOneWidget);
      expect(tester.widget<EditableText>(editor).controller, same(controller));
      await tester.tap(filters);
      await tester.pumpAndSettle();
      expect(find.text('筛选会话'), findsOneWidget);
      await tester.tap(find.widgetWithText(LuminaButton, '完成'));
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      final seeded = () async {
        for (var i = 0; i < 24; i++) {
          await h.repo.createConversation(title: '滚动会话 $i');
        }
      }();
      await tester.pumpAndSettle();
      await seeded;
      await tester.pumpAndSettle();
      final viewport = find.byType(ReorderableList);
      final floating = find.byKey(
        const ValueKey('conversation-floating-controls'),
      );
      final cardBefore = tester.getRect(card);
      final searchBefore = tester.getRect(search);
      final viewportBefore = tester.getRect(viewport);
      expect(viewportBefore.top, closeTo(tester.getRect(floating).top, .1));
      expect(viewportBefore.top, lessThan(cardBefore.top));
      expect(
        (tester.widget<ReorderableList>(viewport).padding! as EdgeInsets).top,
        greaterThan(cardBefore.bottom - viewportBefore.top),
      );
      final first = find
          .descendant(
            of: viewport,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is LuminaSurface &&
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'conversation-row-',
                  ),
            ),
          )
          .first;
      final firstKey = tester.widget<LuminaSurface>(first).key!;
      final row = find.byKey(firstKey);
      final rowBefore = tester.getRect(row);
      expect(rowBefore.top, greaterThan(cardBefore.bottom));
      await tester.drag(
        viewport,
        Offset(0, -(rowBefore.top - cardBefore.top + rowBefore.height * .3)),
      );
      await tester.pumpAndSettle();
      final rowAfter = tester.getRect(row);
      expect(tester.getRect(card), cardBefore);
      expect(tester.getRect(search), searchBefore);
      expect(tester.getRect(viewport), viewportBefore);
      expect(rowAfter.top, lessThan(rowBefore.top));
      expect(rowAfter.overlaps(cardBefore), isTrue);
      expect(h.realtime.attempts, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
