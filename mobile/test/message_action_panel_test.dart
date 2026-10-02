import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/chat/presentation/message_action_panel.dart';

void main() {
  testWidgets('message actions stay by the bubble and dispatch after closing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 32),
              Builder(
                builder: (messageContext) => GestureDetector(
                  onLongPress: () => showChatMessageActionPanel(
                    context: messageContext,
                    onReply: () => selected.add('reply'),
                    onCopy: () => selected.add('copy'),
                    onSelectText: () => selected.add('select'),
                    onExplain: () => selected.add('explain'),
                  ),
                  child: const SizedBox(
                    key: ValueKey('message'),
                    width: 180,
                    height: 56,
                    child: Text('消息内容'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    for (final (caption, expected) in [
      ('引用', 'reply'),
      ('复制', 'copy'),
      ('选字', 'select'),
      ('解释', 'explain'),
    ]) {
      await tester.longPress(find.byKey(const ValueKey('message')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('message-action-panel'));
      expect(panel, findsOneWidget);
      expect(
        tester.getTopLeft(panel).dy,
        greaterThan(
          tester.getBottomLeft(find.byKey(const ValueKey('message'))).dy,
        ),
      );
      await tester.tap(find.text(caption));
      await tester.pumpAndSettle();
      expect(selected.last, expected);
      expect(panel, findsNothing);
    }

    await tester.longPress(find.byKey(const ValueKey('message')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 450));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-action-panel')), findsNothing);
    expect(selected, ['reply', 'copy', 'select', 'explain']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel fits above a message near the bottom edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Builder(
                builder: (messageContext) => GestureDetector(
                  onLongPress: () => showChatMessageActionPanel(
                    context: messageContext,
                    onReply: () {},
                    onCopy: () {},
                    onSelectText: () {},
                    onExplain: () {},
                  ),
                  child: const SizedBox(
                    key: ValueKey('bottom-message'),
                    width: 180,
                    height: 56,
                    child: Text('靠近底部'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byKey(const ValueKey('bottom-message')));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('message-action-panel'));
    expect(
      tester.getBottomLeft(panel).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('bottom-message'))).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
