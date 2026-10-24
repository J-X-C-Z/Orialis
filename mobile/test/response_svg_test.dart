import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_svg.dart';
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
    '<defs><linearGradient id="paint"><stop offset="0" stop-color="#00f"/>'
    '<stop offset="1" stop-color="#0ff"/></linearGradient></defs>'
    '<rect x="10" y="10" width="80" height="80" fill="url(#paint)"/></svg>';

Map<String, Object> document(String source) => {
  'version': 1,
  'fallback': '蓝色渐变矩形',
  'blocks': [
    {
      'type': 'svg',
      'items': [
        {'label': '蓝色渐变矩形', 'source': source},
      ],
    },
  ],
};

Widget host(String source, {bool enabled = true}) => MaterialApp(
  home: LuminaTheme(
    child: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 240,
            child: SafeMarkdownView(
              source: '```orialis-ui\n${jsonEncode(document(source))}\n```',
              allowResponseUi: enabled,
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test('shared six-component contract parses, preserving SVG source', () {
    final parsed = ResponseUiDocument.parse(
      File('../docs/contracts/response-ui-v1.example.json').readAsStringSync(),
    )!;
    expect(parsed.blocks.map((b) => b.type), [
      'metrics',
      'chart',
      'tabs',
      'checklist',
      'choices',
      'svg',
    ]);
    expect(parsed.blocks.last.items.single.source, contains('<svg'));
    expect(ResponseSvg.isValid(svg), isTrue);
    expect(
      ResponseSvg.isValid(svg.replaceFirst('url(#paint)', 'burlywood')),
      isTrue,
    );
  });

  test(
    'rejects active content, remote resources, malformed and unbounded SVG',
    () {
      final invalid = [
        '',
        '<svg>',
        '<html/>',
        svg.replaceFirst('100 100', '0 100'),
        svg.replaceFirst('100 100', 'Infinity 100'),
        svg.replaceFirst('100 100', '10001 100'),
        svg.replaceFirst('viewBox', 'onload="alert(1)" viewBox'),
        svg.replaceFirst('</svg>', '<script>alert(1)</script></svg>'),
        svg.replaceFirst(
          '</svg>',
          '<image href="https://example.com/a"/></svg>',
        ),
        svg.replaceFirst('</svg>', '<foreignObject/></svg>'),
        svg.replaceFirst('</svg>', '<text>hidden label</text></svg>'),
        svg.replaceFirst('url(#paint)', 'url(https://example.com/a)'),
        svg.replaceFirst('url(#paint)', 'URL(https://example.com/a)'),
        svg.replaceFirst('fill="url(#paint)"', 'style="fill:red"'),
        '<!DOCTYPE svg>$svg',
        '<?xml version="1.0"?>$svg',
        svg.replaceFirst('</svg>', '${'<g/>' * 257}</svg>'),
        svg.replaceFirst('</svg>', '${' ' * 16000}</svg>'),
      ];
      for (final source in invalid) {
        expect(ResponseSvg.isValid(source), isFalse, reason: source);
        expect(ResponseUiDocument.parse(jsonEncode(document(source))), isNull);
      }
    },
  );

  testWidgets(
    'renders at narrow large text, copies source and opens zoom viewer',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(host(svg));
      await tester.pumpAndSettle();
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('复制 SVG'));
      await tester.tap(find.text('复制 SVG'));
      await tester.pumpAndSettle();
      expect(clipboard, svg);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放大查看'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('关闭图形'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(svg, enabled: false));
      expect(find.byType(SvgPicture), findsNothing);
    },
  );

  testWidgets('bad path data displays a recoverable error', (tester) async {
    await tester.pumpWidget(
      host(
        svg.replaceFirst(
          '<rect x="10" y="10" width="80" height="80" fill="url(#paint)"/>',
          '<path d="M invalid"/>',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('图形暂时无法显示'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
