import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

import 'lumina_components_test.dart' show harness;

void main() {
  testWidgets(
    'drag source stays mounted for edge auto-scroll and releases afterward',
    (tester) async {
      final controller = ScrollController();
      final sourceKey = GlobalKey<_MountedProbeState>();
      var reordered = false;
      await tester.pumpWidget(
        harness(
          CustomScrollView(
            controller: controller,
            slivers: [
              SliverList.builder(
                itemCount: 40,
                itemBuilder: (context, index) {
                  final key = index == 0
                      ? sourceKey
                      : ValueKey('row-state-$index');
                  return LuminaLongPressOrderable<int>(
                    key: ValueKey('order-$index'),
                    item: index,
                    group: 'rows',
                    onReorder: (dragged, target) {
                      reordered = dragged == 0 && target == 18;
                    },
                    feedback: Text('drag-$index'),
                    child: SizedBox(
                      height: 80,
                      child: _MountedProbe(key: key, label: 'row-$index'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
      final sourceState = sourceKey.currentState!;
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('row-0')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(const Offset(200, 580));
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await gesture.moveBy(Offset(i.isEven ? 1 : -1, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, greaterThan(800));
      expect(sourceState.mounted, isTrue);
      expect(find.text('row-18'), findsOneWidget);
      await gesture.moveTo(tester.getCenter(find.text('row-18')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(reordered, isTrue);
      expect(sourceState.mounted, isFalse);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );
}

class _MountedProbe extends StatefulWidget {
  const _MountedProbe({required this.label, super.key});
  final String label;

  @override
  State<_MountedProbe> createState() => _MountedProbeState();
}

class _MountedProbeState extends State<_MountedProbe> {
  @override
  Widget build(BuildContext context) => Center(child: Text(widget.label));
}
