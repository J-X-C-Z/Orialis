import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/features/events/application/quick_event_service.dart';
import 'package:orialis_mobile/features/events/presentation/quick_event_button.dart';

void main() {
  Future<void> host(
    WidgetTester tester, {
    required Future<void> Function(QuickEventRequest) submit,
    Future<String?> Function()? check,
  }) => tester.pumpWidget(
    MaterialApp(
      home: LuminaTheme(
        data: const LuminaThemeData(motionScale: 0),
        child: SingleChildScrollView(
          child: QuickEventEditor(submit: submit, checkAvailable: check),
        ),
      ),
    ),
  );

  testWidgets('offline backend is announced before typing', (tester) async {
    await host(
      tester,
      submit: (_) async {},
      check: () async => 'Azure Hermes 当前离线，可以先写好，连接后再发送。',
    );
    await tester.pump();
    expect(find.textContaining('当前离线'), findsOneWidget);
    expect(find.byType(LuminaIcon), findsWidgets);
  });

  testWidgets('online backend shows no notice; errors replace it', (
    tester,
  ) async {
    await host(
      tester,
      submit: (_) async => throw StateError('Azure Hermes 暂未连接，请稍后重试'),
      check: () async => null,
    );
    await tester.pump();
    expect(find.textContaining('离线'), findsNothing);
    await tester.enterText(find.byType(EditableText), '明天开会');
    await tester.tap(find.text('发送给后台'));
    await tester.pumpAndSettle();
    expect(find.text('Azure Hermes 暂未连接，请稍后重试'), findsOneWidget);
  });

  testWidgets('a failing pre-check stays silent', (tester) async {
    await host(
      tester,
      submit: (_) async {},
      check: () => Future<String?>.error(Exception('network')),
    );
    await tester.pump();
    expect(find.textContaining('离线'), findsNothing);
  });
}
