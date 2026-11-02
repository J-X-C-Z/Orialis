import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(400, 600)),
    child: LuminaTheme(
      brightness: Brightness.light,
      highPerformanceMode: false,
      child: Center(child: child),
    ),
  ),
);

class _TapCounter extends StatefulWidget {
  const _TapCounter();

  @override
  State<_TapCounter> createState() => _TapCounterState();
}

class _TapCounterState extends State<_TapCounter> {
  var taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => taps++),
    child: SizedBox(width: 240, height: 72, child: Text('taps $taps')),
  );
}

void main() {
  testWidgets('settled completion rows keep their outer shadows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        LuminaCompletionList(
          children: const [
            LuminaListRow(key: ValueKey('row'), title: 'Milestone'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final clips = tester.widgetList<ClipPath>(find.byType(ClipPath));
    expect(clips, isNotEmpty);
    expect(clips.every((clip) => clip.clipBehavior == Clip.none), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded reveal bypasses clipping and keeps child state', (
    tester,
  ) async {
    var visible = true;
    late StateSetter setHostState;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return LuminaReveal(visible: visible, child: const _TapCounter());
          },
        ),
      ),
    );

    ClipRect revealClip() => tester.widget<ClipRect>(find.byType(ClipRect));

    expect(revealClip().clipBehavior, Clip.none);
    await tester.tap(find.text('taps 0'));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);

    setHostState(() => visible = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(revealClip().clipBehavior, Clip.hardEdge);
    await tester.pumpAndSettle();
    expect(revealClip().clipBehavior, Clip.hardEdge);

    setHostState(() => visible = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(revealClip().clipBehavior, Clip.hardEdge);
    await tester.pumpAndSettle();

    expect(revealClip().clipBehavior, Clip.none);
    expect(find.text('taps 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass backdrop stack lets the material shadow escape', (
    tester,
  ) async {
    final policy = LuminaBlurPolicy.instance;
    policy.useFlowingGlass();
    addTearDown(policy.useFlowingGlass);
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 240,
          height: 56,
          child: LuminaSurface(
            glass: true,
            backdrop: true,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );

    final filter = find.byType(BackdropFilter);
    expect(filter, findsOneWidget);
    final stack = find.ancestor(of: filter, matching: find.byType(Stack)).first;
    expect(tester.widget<Stack>(stack).clipBehavior, Clip.none);
    expect(tester.takeException(), isNull);
  });
}
