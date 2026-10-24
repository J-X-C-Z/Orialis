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

  testWidgets(
    'old status and review notices stay out of history and previews',
    (tester) async {
      final h = await openChat(tester);
      final contents = [
        '已经完成整理。',
        '⏳ Working — 3 min — terminal',
        '💾 Self-improvement review: Memory updated',
      ];
      final seed = () async {
        for (var i = 0; i < contents.length; i++) {
          await h.repo.applyRemoteMessage({
            'conversationId': h.id,
            'id': 'history-$i',
            'role': 'assistant',
            'content': contents[i],
            'createdAt': DateTime.utc(2026, 10, 24, 0, i).toIso8601String(),
            'version': 1,
          });
        }
      }();
      await tester.pumpAndSettle();
      await seed;
      await tester.pumpAndSettle();
      expect(find.text(contents[0], findRichText: true), findsOneWidget);
      expect(find.textContaining('Working', findRichText: true), findsNothing);
      expect(
        find.textContaining('Self-improvement', findRichText: true),
        findsNothing,
      );
      final stored = (await tester.runAsync(
        () => h.db.select(h.db.messages).get(),
      ))!;
      expect(stored.length, 3);
      await tester.tap(iconAction('返回会话列表'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Self-improvement'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a history window full of hidden notices can still load earlier replies',
    (tester) async {
      final h = await openChat(tester);
      final seed = () async {
        for (var i = 0; i < 65; i++) {
          await h.repo.applyRemoteMessage({
            'conversationId': h.id,
            'id': 'older-$i',
            'role': 'assistant',
            'content': i == 0 ? '更早的实际回复' : '⏳ Working — $i min — terminal',
            'createdAt': DateTime.utc(2026, 10, 24, 0, i).toIso8601String(),
            'version': 1,
          });
        }
      }();
      await tester.pumpAndSettle();
      await seed;
      await tester.pumpAndSettle();
      expect(find.text('查看更早消息'), findsOneWidget);
      await tester.tap(find.text('查看更早消息'));
      await tester.pumpAndSettle();
      expect(find.text('更早的实际回复', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('⏳ Working', findRichText: true),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
