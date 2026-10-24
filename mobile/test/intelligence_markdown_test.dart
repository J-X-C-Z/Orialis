import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';

class _Launcher extends UrlLauncherPlatform {
  final launched = <String>[];
  bool succeeds = true;
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    expect(options.mode, PreferredLaunchMode.externalApplication);
    launched.add(url);
    return succeeds;
  }
}

Widget _host(String source, {double scale = 1, double width = 320}) =>
    MaterialApp(
      home: LuminaTheme(
        highPerformanceMode: true,
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: width,
                child: SafeMarkdownView(source: source),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  test(
    'quotes and dividers split paragraphs and ordered lists retain their start',
    () {
      final blocks = MarkdownBlock.parse(
        'Intro\n> **Quoted** text\n> second line\n---\n7. Seventh\n8. Eighth',
      );
      expect(blocks.map((block) => block.type), [
        MarkdownBlockType.paragraph,
        MarkdownBlockType.quote,
        MarkdownBlockType.divider,
        MarkdownBlockType.ordered,
      ]);
      expect(blocks[1].lines, ['**Quoted** text', 'second line']);
      expect(blocks.last.startNumber, 7);
      final code = MarkdownBlock.parse('```text\n> Literal\n---\n```').single;
      expect(code.type, MarkdownBlockType.code);
      expect(code.lines, ['> Literal', '---']);
    },
  );

  testWidgets(
    'web links open on tap, unsafe schemes stay inert and failures are visible',
    (tester) async {
      final original = UrlLauncherPlatform.instance;
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = original);
      await tester.pumpWidget(
        _host(
          '[Website](https://example.com/guide)\n\n[Script](javascript:alert)\n\n[File](file:///private)',
        ),
      );
      expect(launcher.launched, isEmpty);
      await tester.tap(find.text('Website', findRichText: true));
      await tester.pump();
      expect(launcher.launched, ['https://example.com/guide']);
      await tester.tap(find.text('Script', findRichText: true));
      await tester.tap(find.text('File', findRichText: true));
      expect(launcher.launched, hasLength(1));
      launcher.succeeds = false;
      await tester.tap(find.text('Website', findRichText: true));
      await tester.pump();
      expect(find.text('链接未能打开，可以长按消息复制链接'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'body text honors system scaling and code header wraps on narrow screens',
    (tester) async {
      await tester.pumpWidget(_host('Readable text', scale: 1));
      final body = find.text('Readable text', findRichText: true);
      final normalHeight = tester.getSize(body).height;
      await tester.pumpWidget(_host('Readable text', scale: 2));
      expect(tester.getSize(body).height, greaterThan(normalHeight * 1.8));
      await tester.pumpWidget(
        _host(
          '7. Item\n8. Next\n\n> A quotation\n\n```a-long-language-name\ncode\n```',
          scale: 2,
          width: 240,
        ),
      );
      expect(find.text('7.'), findsOneWidget);
      expect(find.text('8.'), findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('A quotation', findRichText: true),
      );
      expect(paragraph.text.toPlainText(), 'A quotation');
      expect(tester.takeException(), isNull);
    },
  );
}
