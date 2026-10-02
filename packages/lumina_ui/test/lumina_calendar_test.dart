import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

import 'lumina_components_test.dart' show harness;

void main() {
  testWidgets('floating header stays fixed as content passes behind', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        LuminaFloatingHeader(
          header: const Center(child: Text('固定胶囊')),
          bodyBuilder: (_, inset) => ListView(
            padding: EdgeInsets.only(top: inset),
            children: List.generate(
              40,
              (i) => SizedBox(height: 60, child: Text('内容 $i')),
            ),
          ),
        ),
      ),
    );
    final header = tester.getTopLeft(find.text('固定胶囊'));
    final row = tester.getTopLeft(find.text('内容 0'));
    expect(row.dy, greaterThan(header.dy));
    await tester.drag(find.byType(ListView), const Offset(0, -70));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('固定胶囊')), header);
    expect(tester.getTopLeft(find.text('内容 0')).dy, lessThan(header.dy));
  });
  testWidgets('empty cards retain titles and date controls fit large text', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LuminaDateNavigator(
                  label: '2026年9月27日',
                  previousLabel: '前一天',
                  nextLabel: '后一天',
                  onPrevious: () {},
                  onNext: () {},
                  onSelectDate: () {},
                ),
                const LuminaTitledContentCard(
                  title: '当天截止',
                  emptyText: '没有截止事项',
                  children: [],
                ),
              ],
            ),
          ),
        ),
        scale: 2,
      ),
    );
    expect(find.text('当天截止'), findsOneWidget);
    expect(find.text('没有截止事项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
