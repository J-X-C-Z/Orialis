import 'dart:async';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'lumina_components_test.dart' show harness;

void main() {
  const channel = MethodChannel('top.jxcz.orialis/haptics');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LuminaCardMemory.initialize();
  });
  testWidgets('undo from completed uses the shared exit animation', (
    tester,
  ) async {
    var completed = true;
    late StateSetter update;
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LuminaCompletionList(
                  empty: const SizedBox(
                    height: 48,
                    child: Text('no completed tasks'),
                  ),
                  children: [
                    if (completed)
                      SizedBox(
                        key: const ValueKey('done'),
                        height: 100,
                        child: LuminaCheck(
                          value: true,
                          onChanged: (_) async =>
                              update(() => completed = false),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(LuminaCheck));
    await tester.pump();
    expect(find.byKey(const ValueKey('done')), findsNWidgets(2));
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      tester.getSize(find.byType(LuminaCompletionList)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('done')), findsNothing);
    expect(tester.getSize(find.byType(LuminaCompletionList)).height, 48);
  });

  testWidgets('filter changes retain shared rows and can reverse mid-exit', (
    tester,
  ) async {
    var alternate = false;
    late StateSetter update;
    Widget row(String id) =>
        SizedBox(key: ValueKey(id), height: 80, child: Text(id));
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LuminaCompletionList(
                  animateChanges: true,
                  children: [
                    row('shared'),
                    if (alternate) row('new') else row('old'),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    final shared = tester.element(find.byKey(const ValueKey('shared')).first);
    update(() => alternate = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('old')), findsNWidgets(2));
    expect(
      tester.element(find.byKey(const ValueKey('shared')).first),
      same(shared),
    );
    await tester.pump(const Duration(milliseconds: 80));
    update(() => alternate = false);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('old')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('new')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('last completion never shrinks below the empty footprint', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LuminaCompletionList(
                  empty: const SizedBox(height: 64, child: Text('empty')),
                  children: [
                    if (visible)
                      SizedBox(
                        key: const ValueKey('last'),
                        height: 120,
                        child: LuminaCheck(
                          value: false,
                          onChanged: (_) async {
                            update(() => visible = false);
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(LuminaCheck));
    await tester.pump();
    for (var frame = 0; frame < 45; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getSize(find.byType(LuminaCompletionList)).height,
        greaterThanOrEqualTo(64),
      );
    }
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(LuminaCompletionList)).height, 64);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project card expands in place and reverses without remount', (
    tester,
  ) async {
    var expanded = false;
    late StateSetter update;
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LuminaExpandableCard(
                  expanded: expanded,
                  header: const Text('project'),
                  summary: const SizedBox(height: 30, child: Text('summary')),
                  detailBuilder: (_) =>
                      const SizedBox(height: 200, child: Text('milestones')),
                  onExpand: () => update(() => expanded = true),
                );
              },
            ),
          ),
        ),
      ),
    );
    final card = find.byType(LuminaExpandableCard);
    final element = tester.element(card);
    final initialHeight = tester.getSize(card).height;
    await tester.tap(find.text('project'));
    await tester.pumpAndSettle();
    expect(tester.element(card), same(element));
    expect(tester.getSize(card).height, greaterThan(initialHeight));
    update(() => expanded = false);
    await tester.pumpAndSettle();
    expect(tester.getSize(card).height, initialHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion in a retained project row closes and reopens', (
    tester,
  ) async {
    var haptics = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) async {
      haptics++;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 320,
            child: LuminaCompletionList(
              children: [
                OrialisListRow(
                  key: const ValueKey('retained'),
                  title: 'milestone',
                  leading: LuminaCheck(value: false, onChanged: (_) async {}),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final row = find.byType(LuminaCompletionList);
    final height = tester.getSize(row).height;
    await tester.tap(find.byType(LuminaCheck));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 170));
    expect(tester.getSize(row).height, lessThan(height));
    expect(haptics, 1);
    await tester.pumpAndSettle();
    expect(tester.getSize(row).height, height);
    expect(find.text('milestone'), findsOneWidget);
  });

  testWidgets('remote removal does not play completion or vibrate', (
    tester,
  ) async {
    var visible = true, haptics = 0;
    late StateSetter update;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) async {
      haptics++;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LuminaCompletionList(
              children: [
                if (visible) const Text('remote', key: ValueKey('remote')),
              ],
            );
          },
        ),
      ),
    );
    update(() => visible = false);
    await tester.pump();
    expect(find.text('remote'), findsNothing);
    expect(haptics, 0);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'reduced-motion branch navigation crossfades without displacement',
    (tester) async {
      var index = 0;
      late StateSetter update;
      await tester.pumpWidget(
        harness(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return LuminaBranchTransition(
                index: index,
                children: const [
                  Center(child: Text('first')),
                  Center(child: Text('second')),
                ],
              );
            },
          ),
          reduced: true,
        ),
      );
      update(() => index = 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      for (final transform in tester.widgetList<FractionalTranslation>(
        find.byType(FractionalTranslation),
      )) {
        expect(transform.translation, Offset.zero);
      }
      await tester.pumpAndSettle();
      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);
    },
  );
  testWidgets('save starts immediately; removed row closes then leaves once', (
    tester,
  ) async {
    var visible = true, writes = 0, haptics = 0;
    late StateSetter update;
    final saved = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'confirm');
      haptics++;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      harness(
        Center(
          child: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LuminaCompletionList(
                  empty: const Text('empty'),
                  children: [
                    if (visible)
                      OrialisListRow(
                        key: const ValueKey('task'),
                        title: 'task',
                        depth: LuminaSurfaceDepth.recessed,
                        trailing: LuminaCheck(
                          value: false,
                          onChanged: (_) async {
                            writes++;
                            await saved.future;
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(LuminaCheck));
    await tester.tap(find.byType(LuminaCheck));
    expect(writes, 1);
    expect(haptics, 0);
    // The stream can publish the committed state before the write future resolves.
    update(() => visible = false);
    await tester.pump();
    expect(find.text('task'), findsOneWidget);
    saved.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.text('task'), findsOneWidget);
    expect(haptics, 1);
    await tester.pumpAndSettle();
    expect(find.text('task'), findsNothing);
    expect(find.text('empty'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save preserves row without success haptic', (
    tester,
  ) async {
    var haptics = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) async {
      haptics++;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      harness(
        Center(
          child: LuminaCompletionList(
            children: [
              OrialisListRow(
                key: const ValueKey('task'),
                title: 'task',
                trailing: LuminaCheck(
                  value: false,
                  onChanged: (_) async {
                    throw StateError('offline');
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(LuminaCheck));
    await tester.pumpAndSettle();
    expect(find.text('task'), findsOneWidget);
    expect(find.text('未能保存完成状态，请重试。'), findsOneWidget);
    expect(haptics, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('branch transitions preserve state and allow rapid retargeting', (
    tester,
  ) async {
    var index = 0;
    late StateSetter update;
    final field = TextEditingController(text: 'keep me');
    addTearDown(field.dispose);
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LuminaBranchTransition(
              index: index,
              children: [
                Center(child: LuminaTextField(controller: field)),
                const Center(child: Text('second')),
                const Center(child: Text('third')),
              ],
            );
          },
        ),
      ),
    );
    update(() => index = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('keep me'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    update(() => index = 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    update(() => index = 0);
    await tester.pumpAndSettle();
    expect(find.text('keep me'), findsOneWidget);
    expect(find.text('second'), findsNothing);
    expect(find.text('third'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
