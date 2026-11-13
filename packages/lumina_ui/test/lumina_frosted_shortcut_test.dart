import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

// Exercise the real shortcut without the app's unrelated native plugins.
// ignore: avoid_relative_lib_imports
import '../../../mobile/lib/features/chat/presentation/chat_shortcut_button.dart';

Widget _host(Widget child, {bool opaque = false, bool contrast = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(highContrast: contrast, disableAnimations: true),
        child: LuminaTheme(
          highPerformanceMode: true,
          reduceTransparency: opaque,
          data: const LuminaThemeData(neumorphic: true, neumorphicGlass: true),
          child: Center(child: child),
        ),
      ),
    );

void main() {
  testWidgets(
    'shortcut keeps small live frost and tap/hold in performance mode',
    (tester) async {
      LuminaBlurPolicy.instance.useHighPerformanceChrome();
      var taps = 0, holds = 0;
      await tester.pumpWidget(
        _host(
          ChatShortcutButton(
            tooltip: '快捷添加',
            onPressed: () => taps++,
            onDefaultChat: () => holds++,
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
      final size = tester.getSize(find.byType(ChatShortcutButton));
      expect(size.width, size.height);
      expect(size.width, greaterThanOrEqualTo(48));
      await tester.tap(find.byType(ChatShortcutButton));
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(ChatShortcutButton));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(holds, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('frosted shortcut respects opaque and high contrast settings', (
    tester,
  ) async {
    for (final settings in [(true, false), (false, true)]) {
      await tester.pumpWidget(
        _host(
          ChatShortcutButton(
            tooltip: '快捷添加',
            onPressed: () {},
            onDefaultChat: null,
          ),
          opaque: settings.$1,
          contrast: settings.$2,
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ChatShortcutButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
