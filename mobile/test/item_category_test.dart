import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';
import 'package:orialis_mobile/features/categories/item_category.dart';

void main() {
  testWidgets(
    'unknown category stays readable and picker returns an explicit category',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xffe1e4e8),
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => Center(
              child: CategoryField(
                value: 'future-category',
                onChanged: (value) => selected = value,
              ),
            ),
          ),
          builder: (_, child) => LuminaTheme(
            data: const LuminaThemeData(neumorphic: true),
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 14),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('其他'), findsWidgets);
      expect(selected, isNull);
      await tester.tap(find.byType(CategoryField));
      await tester.pumpAndSettle();
      expect(find.text('选择分类'), findsOneWidget);
      await tester.tap(find.text('课程').last);
      await tester.pumpAndSettle();
      expect(selected, 'course');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
