import 'package:flutter_test/flutter_test.dart';

import 'package:fangcun_devtools/main.dart';

void main() {
<<<<<<< HEAD
  testWidgets('renders the Rust Server login form', (tester) async {
    await tester.pumpWidget(const FangcunDevToolsApp());

    expect(find.text('Flutter 最小客户端'), findsOneWidget);
    expect(find.text('Rust Server 地址'), findsOneWidget);
    expect(find.text('登录并读取数据'), findsOneWidget);
=======
  testWidgets('developer console renders the island preview', (tester) async {
    await tester.pumpWidget(const FangcunDevToolsApp());

    expect(find.text('原生事件预览'), findsOneWidget);
    expect(find.text('开发者模式'), findsOneWidget);
    expect(find.text('Focus 开始'), findsOneWidget);
    expect(find.text('SUPER ISLAND / FALLBACK PREVIEW'), findsOneWidget);
  });

  testWidgets('developer event updates the local preview', (tester) async {
    await tester.pumpWidget(const FangcunDevToolsApp());
    await tester.tap(find.text('Focus 完成'));
    // The preview intentionally contains an indeterminate progress indicator,
    // so the tree never becomes fully settled. Advance the finite event UI
    // animation instead of waiting for all animations to stop.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('C++训练'), findsOneWidget);
    expect(find.text('focus.complete'), findsOneWidget);
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
  });
}
