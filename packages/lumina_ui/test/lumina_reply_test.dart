import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

import 'lumina_components_test.dart' show harness;

void main() {
  testWidgets('navigation edge compresses once and releases inside the well', (
    tester,
  ) async {
    var haptics = 0;
    LuminaHaptics.confirmHandler = () async {
      haptics++;
    };
    addTearDown(() => LuminaHaptics.confirmHandler = null);
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 300,
            child: LuminaSlidingSelection(
              index: 0,
              count: 3,
              onDragEnd: (_) {},
              child: const SizedBox(width: 300, height: 48),
            ),
          ),
        ),
      ),
    );
    final well = find.byType(LuminaSlidingSelection);
    final start = tester.getTopLeft(well) + const Offset(50, 24);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    expect(haptics, 1, reason: 'drag pickup');
    await gesture.moveTo(start - const Offset(100, 0));
    await tester.pump();
    final deformation = tester.widget<Transform>(
      find.byKey(const ValueKey('lumina-selection-deformation')),
    );
    expect(deformation.transform.entry(0, 0), lessThan(1));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('lumina-selection-lens'))).dx,
      greaterThanOrEqualTo(tester.getTopLeft(well).dx),
    );
    await gesture.moveTo(start - const Offset(120, 0));
    await tester.pump();
    expect(haptics, 2); // one pickup and one edge contact
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('lumina-selection-deformation')),
          )
          .transform
          .entry(0, 0),
      closeTo(1, .001),
    );
  });

  testWidgets('quote source and dismissal remain separate accessible actions', (
    tester,
  ) async {
    var source = 0;
    var dismiss = 0;
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 280,
            child: LuminaQuotePreview(
              title: 'Assistant',
              text: 'Original message',
              onTap: () => source++,
              onDismiss: () => dismiss++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Original message'));
    expect(source, 1);
    expect(dismiss, 0);
    await tester.tap(find.byType(LuminaIconButton));
    expect(source, 1);
    expect(dismiss, 1);
    expect(
      tester.getSize(find.byType(LuminaIconButton)).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('compact top bar retains actions and live glass', (tester) async {
    await tester.pumpWidget(
      harness(
        const Center(
          child: LuminaTopBar(
            title: 'Today',
            actions: [
              LuminaIconButton(
                icon: LuminaIcon(LuminaIcons.add),
                onPressed: null,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      tester.getSize(find.byType(LuminaTopBar)).height,
      lessThanOrEqualTo(64),
    );
    expect(tester.getSize(find.byType(LuminaIconButton)).height, 48);
  });
}
