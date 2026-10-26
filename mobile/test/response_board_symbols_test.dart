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
}
