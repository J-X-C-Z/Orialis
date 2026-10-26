import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/chat/domain/chat_transcript.dart';
import 'package:orialis_mobile/features/chat/presentation/chat_progress_summary.dart';

import 'lumina_chat_flow_test.dart' show openChat;

const _progress = 'progress_0123456789abcdef01234567';
const _final = 'final_0123456789abcdef01234567';
const _note = '已核对杭州高铁班次，接下来比较自驾耗时。';

Message _message(
  String id, {
  String? anchor = 'q1',
  String role = 'assistant',
}) => Message(
  conversationId: 'chat',
  id: id,
  role: role,
  content: _note,
  replyToMessageId: anchor,
  createdAt: '2026-10-25T01:17:00Z',
  attachmentsJson: '[]',
  syncStatus: 'synced',
  remoteVersion: 1,
);

Widget _host({required bool completed}) => LuminaTheme(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(),
      child: Center(
        child: SizedBox(
          width: 300,
          child: ChatProgressSummary(content: _note, completed: completed),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('only exact assistant reserved IDs are summaries', () {
    expect(isChatProgressSummary(_message(_progress)), isTrue);
    for (final id in [
      'progress_regular-message',
      'progress_0123456789abcdef0123456',
      'progress_0123456789ABCDEF01234567',
    ]) {
      expect(isChatProgressSummary(_message(id)), isFalse);
    }
    expect(isChatProgressSummary(_message(_progress, role: 'user')), isFalse);
  });

  test('completion requires durable final on the same user anchor', () {
    expect(
      completedSummaryAnchors([
        _message(_progress),
        _message('initial_0123456789abcdef01234567'),
        _message('msg_interim'),
        _message(_final, anchor: 'q2'),
        _message('final_0123456789abcdef01234568', anchor: null),
        _message('final_0123456789abcdef01234569', role: 'user'),
      ]),
      {'q2'},
    );
    expect(
      completedSummaryAnchors([_message('msg_legacy'), _message(_progress)]),
      isEmpty,
    );
  });

  testWidgets('completion collapses live summary and permits reopening', (
    tester,
  ) async {
    await tester.pumpWidget(_host(completed: false));
    expect(find.text(_note, findRichText: true), findsOneWidget);
    await tester.tap(find.text('处理摘要'));
    await tester.pump();
    await tester.tap(find.text('处理摘要'));
    await tester.pump();
    expect(find.text(_note, findRichText: true), findsOneWidget);

    await tester.pumpWidget(_host(completed: true));
    expect(find.text(_note, findRichText: true), findsNothing);
    await tester.tap(find.text('处理摘要'));
    await tester.pump();
    expect(find.text(_note, findRichText: true), findsOneWidget);
    await tester.pumpWidget(_host(completed: true));
    expect(find.text(_note, findRichText: true), findsOneWidget);
  });

  testWidgets('completed history starts collapsed', (tester) async {
    await tester.pumpWidget(_host(completed: true));
    expect(find.text(_note, findRichText: true), findsNothing);
    expect(find.text('处理摘要'), findsOneWidget);
  });

  testWidgets('chat hides only summary time and folds on same-anchor final', (
    tester,
  ) async {
    final h = await openChat(tester);
    final semantics = tester.ensureSemantics();
    Future<void> add(String id, String content, String anchor) async {
      final pending = h.repo.applyRemoteMessage({
        'conversationId': h.id,
        'id': id,
        'role': 'assistant',
        'content': content,
        'replyToMessageId': anchor,
        'createdAt': '2026-10-25T01:${id == _progress ? '17' : '18'}:00Z',
        'version': 1,
      });
      await tester.pumpAndSettle();
      await pending;
      await tester.pumpAndSettle();
    }

    await add(_progress, _note, 'q1');
    expect(find.text(_note, findRichText: true), findsOneWidget);
    expect(
      find.byKey(const ValueKey('message-status-$_progress')),
      findsNothing,
    );
    await add('initial_0123456789abcdef01234567', '我先比较这两种出行方式。', 'q1');
    await add('msg_interim', '接下来核对停车费用。', 'q1');
    expect(find.text(_note, findRichText: true), findsOneWidget);
    expect(
      find.byKey(const ValueKey('message-status-msg_interim')),
      findsOneWidget,
    );
    await add('final_0123456789abcdef01234568', '另一轮的完整答复。', 'q2');
    expect(find.text(_note, findRichText: true), findsOneWidget);
    await add(_final, '杭州出行方式的完整比较。', 'q1');
    expect(find.text(_note, findRichText: true), findsNothing);
    expect(find.text('杭州出行方式的完整比较。', findRichText: true), findsOneWidget);
    expect(
      find.byKey(const ValueKey('message-status-$_final')),
      findsOneWidget,
    );
    await tester.tap(find.text('处理摘要'));
    await tester.pumpAndSettle();
    expect(find.text(_note, findRichText: true), findsOneWidget);
    expect(
      find.byKey(const ValueKey('message-status-$_progress')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
