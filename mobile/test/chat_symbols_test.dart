import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/chat_symbols.dart';

class _ChatSymbolBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = File(key).readAsBytesSync();
    return ByteData.sublistView(bytes);
  }
}

Widget _host(Widget child, {bool dark = false, bool reduced = false}) =>
    DefaultAssetBundle(
      bundle: _ChatSymbolBundle(),
      child: MaterialApp(
        home: LuminaTheme(
          brightness: dark ? Brightness.dark : Brightness.light,
          child: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(body: Center(child: child)),
          ),
        ),
      ),
    );

void main() {
  test('maps known decorative emoji and leaves unknown symbols untouched', () {
    const examples = {
      '🤔': ChatSymbolKind.thinking,
      '🔍': ChatSymbolKind.search,
      '⚙️': ChatSymbolKind.working,
      '✅': ChatSymbolKind.success,
      '❌': ChatSymbolKind.error,
      '📎': ChatSymbolKind.attachment,
      '📝': ChatSymbolKind.summary,
      '📊': ChatSymbolKind.chart,
      '💻': ChatSymbolKind.code,
      '📤': ChatSymbolKind.send,
      '📋': ChatSymbolKind.copy,
      'ℹ️': ChatSymbolKind.info,
    };
    for (final entry in examples.entries) {
      expect(chatSymbolForEmoji(entry.key), entry.value, reason: entry.key);
    }
    expect(chatSymbolForEmoji('🔮'), isNull);
    expect(chatSymbolForEmoji('original user text'), isNull);
  });

  testWidgets('all symbols load as SVG assets', (tester) async {
    await tester.pumpWidget(
      _host(
        Wrap(
          children: ChatSymbolKind.values
              .map((kind) => ChatSymbol(kind, animated: false))
              .toList(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(ChatSymbol),
      findsNWidgets(ChatSymbolKind.values.length),
    );
    expect(tester.takeException(), isNull);
    for (final kind in ChatSymbolKind.values) {
      final svg = File('assets/chat_symbols/${kind.name}.svg')
          .readAsStringSync();
      expect(svg, contains('viewBox="0 0 24 24"'), reason: kind.name);
      expect(svg, contains('stroke-width="1.7"'), reason: kind.name);
    }
  });

  testWidgets('theme tint changes with brightness and explicit color wins', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const ChatSymbol(ChatSymbolKind.thinking)));
    final light = tester
        .widget<SvgPicture>(find.byType(SvgPicture))
        .colorFilter;
    await tester.pumpWidget(
      _host(const ChatSymbol(ChatSymbolKind.thinking), dark: true),
    );
    final dark = tester.widget<SvgPicture>(find.byType(SvgPicture)).colorFilter;
    expect(light, isNot(dark));

    const override = Colors.orange;
    await tester.pumpWidget(
      _host(const ChatSymbol(ChatSymbolKind.thinking, color: override)),
    );
    expect(
      tester.widget<SvgPicture>(find.byType(SvgPicture)).colorFilter,
      ColorFilter.mode(override, BlendMode.srcIn),
    );
  });

  testWidgets(
    'reduced motion stops the repeating phase and semantics is single',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const ChatSymbol(ChatSymbolKind.thinking, semanticLabel: '正在思考')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(
        _host(
          const ChatSymbol(ChatSymbolKind.thinking, semanticLabel: '正在思考'),
          reduced: true,
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.bySemanticsLabel('正在思考'), findsOneWidget);
      semantics.dispose();
    },
  );

  test('browser preview assets animate only the meaningful states', () {
    const animated = {'thinking', 'search', 'working', 'success'};
    expect(
      Directory('assets/chat_symbols')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.animated.svg'))
          .map(
            (file) =>
                file.uri.pathSegments.last.replaceFirst('.animated.svg', ''),
          )
          .toSet(),
      animated,
    );
    for (final name in animated) {
      final svg = File('assets/chat_symbols/$name.animated.svg')
          .readAsStringSync();
      expect(svg, contains('<animate'), reason: name);
      expect(svg, contains('viewBox="0 0 24 24"'), reason: name);
    }
  });
}
