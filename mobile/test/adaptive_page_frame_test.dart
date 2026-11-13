import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/app/design/lumina_compat.dart'
    show OrialisPageScaffold, DesktopLayoutScope;
import 'package:orialis_mobile/pages/shared/adaptive_layout.dart';

class _Body extends StatefulWidget {
  const _Body({required this.topInset});
  final double topInset;
  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  int count = 0;
  @override
  Widget build(BuildContext context) => ListView(
    key: const ValueKey('frame-body-scroll'),
    padding: EdgeInsets.only(
      top: widget.topInset,
      bottom: MediaQuery.paddingOf(context).bottom + 24,
    ),
    children: [
      Text('计数 $count'),
      LuminaButton(
        key: const ValueKey('frame-increment'),
        onPressed: () => setState(() => count++),
        child: const Text('增加'),
      ),
      for (var i = 0; i < 30; i++) SizedBox(height: 48, child: Text('内容 $i')),
      const SizedBox(
        key: ValueKey('frame-last-row'),
        height: 48,
        child: Text('最后一项'),
      ),
    ],
  );
}

Widget _host({
  String title = '页面标题',
  bool leading = false,
  bool adaptiveHeader = true,
  bool controls = true,
  bool longActions = false,
  double scale = 1,
  bool bottom = false,
}) => WidgetsApp(
  color: const Color(0xff000000),
  builder: (context, _) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      padding: EdgeInsets.only(
        left: MediaQuery.sizeOf(context).width >= 600 ? 32 : 0,
      ),
    ),
    child: LuminaTheme(
      child: LayoutBuilder(
        builder: (context, constraints) => OrialisAdaptiveLayout(
          wide: constraints.maxWidth >= 600,
          tablet: constraints.biggest.shortestSide >= 600,
          navigationWidth: 0,
          child: OrialisPageScaffold(
            title: title,
            adaptiveHeader: adaptiveHeader,
            leading: leading
                ? LuminaIconButton(
                    key: const ValueKey('frame-back'),
                    onPressed: () {},
                    icon: const LuminaIcon(LuminaIcons.back),
                  )
                : null,
            controlsExtent: 48,
            controls: controls
                ? LuminaButton(
                    key: const ValueKey('frame-controls'),
                    onPressed: () {},
                    child: const Text('筛选'),
                  )
                : null,
            actions: [
              for (var i = 0; i < 2; i++)
                if (longActions)
                  LuminaButton(
                    key: ValueKey('frame-action-$i'),
                    onPressed: () {},
                    child: Text(
                      i == 0 ? '将选中的日程归档并同步到所有设备' : '查看所有项目及关联任务的详细资料',
                    ),
                  )
                else
                  LuminaIconButton(
                    key: ValueKey('frame-action-$i'),
                    onPressed: () {},
                    icon: const LuminaIcon(LuminaIcons.add),
                  ),
            ],
            bottomActions: bottom
                ? SizedBox(
                    key: const ValueKey('frame-bottom-actions'),
                    height: 56,
                    child: LuminaButton(
                      onPressed: () {},
                      child: const Text('保存'),
                    ),
                  )
                : null,
            floatingActionButton: bottom
                ? LuminaIconButton(
                    key: const ValueKey('frame-fab'),
                    onPressed: () {},
                    icon: const LuminaIcon(LuminaIcons.add),
                  )
                : null,
            bodyBuilder: (context, inset) => _Body(topInset: inset),
          ),
        ),
      ),
    ),
  ),
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  for (final title in ['今日', '事件', '聊天', '日历', '我的']) {
    testWidgets(
      '$title removes main header actions without leaving an empty rail',
      (tester) async {
        _size(tester, const Size(390, 844));
        await tester.pumpWidget(_host(title: title, controls: false));
        await tester.pumpAndSettle();
        final body = tester.state<_BodyState>(find.byType(_Body));
        expect(find.text(title), findsOneWidget);
        for (final size in [const Size(844, 390), const Size(390, 844)]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(tester.state<_BodyState>(find.byType(_Body)), same(body));
          expect(find.byKey(const ValueKey('frame-action-0')), findsNothing);
          expect(find.byKey(const ValueKey('frame-action-1')), findsNothing);
          expect(
            find.byKey(const ValueKey('adaptive-control-rail')),
            findsNothing,
          );
          expect(
            find.text(title),
            size.width >= 600 ? findsNothing : findsOneWidget,
          );
          if (size.width >= 600) {
            final frame = tester.getRect(
              find.byKey(const ValueKey('frame-body-scroll')),
            );
            expect(frame.width, closeTo(size.width - 32 - 40, .1));
            expect(body.widget.topInset, 0);
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('main controls remain usable without a landscape title', (
    tester,
  ) async {
    _size(tester, const Size(844, 390));
    await tester.pumpWidget(_host(title: '日历'));
    await tester.pumpAndSettle();
    expect(find.text('日历'), findsNothing);
    expect(find.byKey(const ValueKey('frame-action-0')), findsNothing);
    expect(find.byKey(const ValueKey('adaptive-control-rail')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('frame-controls')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('embedded landscape chat does not restore the main title', (
    tester,
  ) async {
    _size(tester, const Size(844, 390));
    await tester.pumpWidget(
      _host(title: '聊天', controls: false, adaptiveHeader: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('聊天'), findsNothing);
    expect(find.byKey(const ValueKey('adaptive-control-rail')), findsNothing);
    expect(find.byKey(const ValueKey('frame-action-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar detail retains its back button and header actions', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(_host(title: '日历', leading: true, controls: false));
    await tester.pumpAndSettle();
    for (final size in [const Size(390, 844), const Size(844, 390)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(find.text('日历'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('frame-back')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('frame-action-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('desktop retains main title and actions', (tester) async {
    _size(tester, const Size(1280, 800));
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xff000000),
        builder: (context, _) => LuminaTheme(
          child: DesktopLayoutScope(
            child: OrialisPageScaffold(
              title: '今日',
              actions: [
                LuminaIconButton(
                  key: const ValueKey('desktop-action'),
                  onPressed: () {},
                  icon: const LuminaIcon(LuminaIcons.add),
                ),
              ],
              body: const Text('桌面内容'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今日'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktop-action')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final controls in [false, true]) {
    testWidgets(
      'generic body state survives portrait, landscape and tablet (controls=$controls)',
      (tester) async {
        _size(tester, const Size(390, 844));
        await tester.pumpWidget(_host(controls: controls));
        await tester.pumpAndSettle();
        final body = tester.state<_BodyState>(find.byType(_Body));
        final scroll = find.byKey(const ValueKey('frame-body-scroll'));
        await tester.tap(find.byKey(const ValueKey('frame-increment')));
        await tester.pumpAndSettle();
        expect(find.text('计数 1'), findsOneWidget);
        for (final size in [
          const Size(844, 390),
          const Size(800, 1280),
          const Size(390, 844),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(tester.state<_BodyState>(find.byType(_Body)), same(body));
          expect(find.text('计数 1'), findsOneWidget);
          final bodyRect = tester.getRect(scroll);
          final title = tester.getRect(find.text('页面标题'));
          if (size.width >= 600) {
            expect(body.widget.topInset, 0);
            expect(find.byType(LuminaTopBar), findsNothing);
            expect(title.right, lessThan(bodyRect.left));
            expect(title.top, lessThan(bodyRect.top + 64));
            final rail = tester.getRect(
              find.byKey(const ValueKey('adaptive-control-rail')),
            );
            expect(rail.width, lessThanOrEqualTo(128));
            expect(rail.height, greaterThan(size.height - 40));
            for (var i = 0; i < 2; i++) {
              expect(
                tester.getRect(find.byKey(ValueKey('frame-action-$i'))).right,
                lessThan(bodyRect.left),
              );
            }
            if (controls) {
              expect(
                tester
                    .getRect(find.byKey(const ValueKey('frame-controls')))
                    .right,
                lessThan(bodyRect.left),
              );
            }
          } else {
            expect(body.widget.topInset, greaterThan(0));
            expect(find.byType(LuminaTopBar), findsOneWidget);
            if (controls) {
              final controlRect = tester.getRect(
                find.byKey(const ValueKey('frame-controls')),
              );
              expect(controlRect.left, greaterThanOrEqualTo(bodyRect.left));
              expect(controlRect.top, greaterThan(title.bottom));
            }
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'short landscape sidebar scrolls long actions and double-size controls',
    (tester) async {
      _size(tester, const Size(844, 320));
      await tester.pumpWidget(_host(longActions: true, scale: 2));
      await tester.pumpAndSettle();
      final sidebar = find.byKey(const ValueKey('adaptive-page-sidebar'));
      final controller = tester.widget<SingleChildScrollView>(sidebar);
      expect(controller.scrollDirection, Axis.vertical);
      for (final target in [
        find.byKey(const ValueKey('frame-action-0')),
        find.byKey(const ValueKey('frame-action-1')),
        find.byKey(const ValueKey('frame-controls')),
      ]) {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'bottom actions and FAB leave the final content accessible at $size',
      (tester) async {
        _size(tester, size);
        await tester.pumpWidget(_host(bottom: true));
        await tester.pumpAndSettle();
        final scroll = find.byKey(const ValueKey('frame-body-scroll'));
        final bottom = find.byKey(const ValueKey('frame-bottom-actions'));
        final fab = find.byKey(const ValueKey('frame-fab'));
        expect(
          tester.getRect(scroll).bottom,
          lessThanOrEqualTo(tester.getRect(bottom).top),
        );
        await tester.drag(scroll, const Offset(0, -3000));
        await tester.pumpAndSettle();
        final last = find.byKey(const ValueKey('frame-last-row'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        final geometry =
            'last=${tester.getRect(last)} scroll=${tester.getRect(scroll)} fab=${tester.getRect(fab)}';
        expect(last.hitTestable(), findsOneWidget, reason: geometry);
        expect(
          tester.getRect(last).overlaps(tester.getRect(fab)),
          isFalse,
          reason: geometry,
        );
        expect(fab.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
