import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

import 'lumina_components_test.dart' show harness;

void main() {
  const channel = MethodChannel('lumina.test/haptics');
  setUp(() async {
    LuminaHaptics.confirmHandler = () => channel.invokeMethod<void>('confirm');
  });
  testWidgets('sliver completion list only builds visible rows', (
    tester,
  ) async {
    var built = 0;
    final keys = List<Key>.generate(1000, (i) => ValueKey('task-$i'));
    await tester.pumpWidget(
      harness(
        CustomScrollView(
          slivers: [
            LuminaCompletionList.sliver(
              itemKeys: keys,
              itemBuilder: (context, index) {
                built++;
                return SizedBox(height: 40, child: Text('row $index'));
              },
            ),
          ],
        ),
      ),
    );
    expect(built, lessThan(50));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('row 20'), findsOneWidget);
    expect(built, lessThan(100));
  });

  testWidgets('sliver rows keep their state when reordered', (tester) async {
    var reversed = false;
    late StateSetter update;
    final keys = [const ValueKey('a'), const ValueKey('b')];
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            final ordered = reversed ? keys.reversed.toList() : keys;
            return CustomScrollView(
              slivers: [
                LuminaCompletionList.sliver(
                  itemKeys: ordered,
                  itemBuilder: (_, index) => _StatefulSliverRow(
                    key: ordered[index],
                    id: ordered[index].value,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('a:0'));
    await tester.pump();
    update(() => reversed = true);
    await tester.pumpAndSettle();
    expect(find.text('a:1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliver filter reverses and settles to a smooth empty row', (
    tester,
  ) async {
    var showRows = true;
    late StateSetter update;
    final keys = [const ValueKey('row')];
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CustomScrollView(
              slivers: [
                LuminaCompletionList.sliver(
                  animateChanges: true,
                  itemKeys: showRows ? keys : const [],
                  empty: const SizedBox(height: 64, child: Text('empty')),
                  itemBuilder: (_, _) => const SizedBox(
                    key: ValueKey('row'),
                    height: 120,
                    child: Text('row'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    update(() => showRows = false);
    await tester.pump();
    expect(find.text('row'), findsOneWidget);
    update(() => showRows = true);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('row'), findsOneWidget);
    update(() => showRows = false);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('empty'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliver exit keeps at least the empty extent every frame', (
    tester,
  ) async {
    var showRow = true;
    late StateSetter update;
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CustomScrollView(
              slivers: [
                LuminaCompletionList.sliver(
                  animateChanges: true,
                  itemKeys: showRow ? const [ValueKey('row')] : const [],
                  empty: const SizedBox(height: 64, child: Text('empty')),
                  itemBuilder: (_, _) => const SizedBox(
                    key: ValueKey('row'),
                    height: 120,
                    child: Text('row'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    update(() => showRow = false);
    await tester.pump();
    final sliver = tester.renderObject<RenderSliver>(find.byType(SliverList));
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(sliver.geometry!.scrollExtent, greaterThanOrEqualTo(64));
    }
    expect(sliver.geometry!.scrollExtent, 64);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliver empty and 1000-row replacements stay lazy', (
    tester,
  ) async {
    var populated = false;
    var replacement = false;
    var built = 0;
    late StateSetter update;
    List<Key> keysFor(bool alternate) => List<Key>.generate(
      1000,
      (index) => ValueKey('${alternate ? 'b' : 'a'}-$index'),
    );
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CustomScrollView(
              slivers: [
                LuminaCompletionList.sliver(
                  animateChanges: true,
                  itemKeys: populated ? keysFor(replacement) : const [],
                  itemBuilder: (_, index) {
                    built++;
                    return SizedBox(height: 56, child: Text('row-$index'));
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
    update(() => populated = true);
    await tester.pump();
    expect(built, lessThan(50));
    expect(tester.takeException(), isNull);
    update(() => replacement = true);
    built = 0;
    await tester.pump();
    expect(built, lessThan(50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliver completion saves after scrolling the row away', (
    tester,
  ) async {
    var writes = 0;
    final saved = Completer<void>();
    final keys = List<Key>.generate(80, (i) => ValueKey('task-$i'));
    await tester.pumpWidget(
      harness(
        CustomScrollView(
          slivers: [
            LuminaCompletionList.sliver(
              itemKeys: keys,
              itemBuilder: (_, index) => SizedBox(
                height: 56,
                child: LuminaCheck(
                  value: false,
                  onChanged: (_) async {
                    writes++;
                    await saved.future;
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(LuminaCheck).first);
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pump();
    saved.complete();
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(tester.takeException(), isNull);
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
                LuminaListRow(
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

  testWidgets('reduced-motion branch navigation fades without displacement', (
    tester,
  ) async {
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
  });
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
                      LuminaListRow(
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
              LuminaListRow(
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

  testWidgets(
    'branch entrance avoids per-frame layout and full-page blending',
    (tester) async {
      var index = 0;
      var layouts = 0;
      late StateSetter update;
      final pages = [
        for (var i = 0; i < 3; i++)
          _BranchLayoutProbe(
            key: ValueKey('probe-$i'),
            onLayout: () => layouts++,
            child: Text('page-$i'),
          ),
      ];
      await tester.pumpWidget(
        harness(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return LuminaBranchTransition(index: index, children: pages);
            },
          ),
        ),
      );
      final first = tester.renderObject(find.byKey(const ValueKey('probe-0')));
      update(() => index = 1);
      await tester.pump();
      final initialLayouts = layouts;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('page-0'), findsNothing);
        expect(find.text('page-1'), findsOneWidget);
        expect(layouts, initialLayouts);
        final fade = tester.widget<FadeTransition>(
          find
              .descendant(
                of: find.byType(LuminaBranchTransition),
                matching: find.byType(FadeTransition),
              )
              .first,
        );
        expect(fade.opacity.value, 1);
      }
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.binding.hasScheduledFrame, isFalse);
      update(() => index = 0);
      await tester.pumpAndSettle();
      expect(
        tester.renderObject(find.byKey(const ValueKey('probe-0'))),
        same(first),
      );
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text('keep me'), findsNothing);
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

class _StatefulSliverRow extends StatefulWidget {
  const _StatefulSliverRow({required this.id, super.key});
  final String id;

  @override
  State<_StatefulSliverRow> createState() => _StatefulSliverRowState();
}

class _StatefulSliverRowState extends State<_StatefulSliverRow> {
  var taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => taps++),
    child: Text('${widget.id}:$taps'),
  );
}

class _BranchLayoutProbe extends SingleChildRenderObjectWidget {
  const _BranchLayoutProbe({
    required this.onLayout,
    required super.child,
    super.key,
  });
  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _BranchLayoutRender(onLayout);
}

class _BranchLayoutRender extends RenderProxyBox {
  _BranchLayoutRender(this.onLayout);
  final VoidCallback onLayout;

  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}
