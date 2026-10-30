import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/chat_symbols.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

Widget _host(String source, {bool assistant = true}) => MaterialApp(
  home: LuminaTheme(
    data: const LuminaThemeData(neumorphic: true, neumorphicGlass: true),
    child: Scaffold(
      body: SafeMarkdownView(source: source, allowResponseUi: assistant),
    ),
  ),
);

void main() {
  testWidgets(
    'known assistant heading decoration uses SVG while source and body remain intact',
    (tester) async {
      const source = '## ✅ 完成\n\n保留正文😀和✅。\n\n> ✅ 原始引用';
      await tester.pumpWidget(_host(source));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChatSymbol>(find.byType(ChatSymbol)).kind,
        ChatSymbolKind.success,
      );
      expect(find.text('完成', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('保留正文😀和✅', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('✅ 原始引用', findRichText: true), findsOneWidget);
      expect(responseUiPlainText(source), source);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'user headings and unknown assistant emoji retain their original text',
    (tester) async {
      await tester.pumpWidget(_host('## ✅ 用户原文', assistant: false));
      expect(find.byType(ChatSymbol), findsNothing);
      expect(find.text('✅ 用户原文', findRichText: true), findsOneWidget);
      await tester.pumpWidget(_host('## 🦊 示例'));
      expect(find.byType(ChatSymbol), findsNothing);
      expect(find.text('🦊 示例', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'streamed progress lines and list decoration use static symbols',
    (tester) async {
      const first = '⚙️ tool_describe: "Reading tool details · 3 tools"';
      const source =
          '$first\n📚 Reading skill orialis-personal-planning\n\n- ✅ 完成';
      await tester.pumpWidget(_host(first));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChatSymbol>(find.byType(ChatSymbol)).kind,
        ChatSymbolKind.working,
      );
      await tester.pumpWidget(_host(source));
      await tester.pumpAndSettle();
      final symbols = tester.widgetList<ChatSymbol>(find.byType(ChatSymbol));
      expect(symbols.map((symbol) => symbol.kind), [
        ChatSymbolKind.working,
        ChatSymbolKind.summary,
        ChatSymbolKind.success,
      ]);
      expect(symbols.every((symbol) => !symbol.animated), isTrue);
      expect(
        find.text(
          'Reading skill orialis-personal-planning',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(responseUiPlainText(source), source);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('user progress, quoted text and code keep emoji unchanged', (
    tester,
  ) async {
    const source = '⚙️ tool_describe\n📚 Reading skill';
    await tester.pumpWidget(_host(source, assistant: false));
    expect(find.byType(ChatSymbol), findsNothing);
    expect(find.text(source, findRichText: true), findsOneWidget);
    await tester.pumpWidget(
      _host('> 📚 引用\n\n`⚙️ literal`\n\n```text\n📚 code\n```'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatSymbol), findsNothing);
    expect(find.text('📚 引用', findRichText: true), findsOneWidget);
    expect(find.text('⚙️ literal', findRichText: true), findsOneWidget);
    expect(find.text('📚 code', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
