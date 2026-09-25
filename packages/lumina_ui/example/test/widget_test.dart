import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui_example/main.dart';

void main() {
  testWidgets('showcase presents its core sections and controls',
      (tester) async {
    await tester.pumpWidget(const LuminaShowcaseApp());
    await tester.pumpAndSettle();

    expect(find.text('Quietly capable.'), findsOneWidget);
    expect(find.text('Color families'), findsOneWidget);
    expect(find.text('Controls'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Expandable card'), 420,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Expandable card'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Preferences'), 420,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Preferences'), findsOneWidget);
    expect(find.text('Open a bottom sheet'), findsOneWidget);
  });
}
