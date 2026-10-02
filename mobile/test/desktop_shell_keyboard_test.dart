import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orialis_mobile/app/design/design_components.dart';
import 'package:orialis_mobile/pages/shell/desktop_shell.dart';

const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
];

Future<GoRouter> _mountShell(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final controllers = List.generate(8, (_) => TextEditingController());
  final router = GoRouter(
    initialLocation: '/destination0',
    routes: [
      GoRoute(
        path: '/auth',
        builder: (_, _) => const Center(child: Text('Authentication route')),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => DesktopShell(navigationShell: shell),
        branches: List.generate(
          8,
          (index) => StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/destination$index',
                builder: (_, _) => Center(
                  child: SizedBox(
                    width: 260,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Destination $index'),
                        LuminaTextField(
                          key: ValueKey('editor$index'),
                          controller: controllers[index],
                          label: 'Editor $index',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
  addTearDown(() {
    router.dispose();
    for (final controller in controllers) {
      controller.dispose();
    }
  });
  await tester.pumpWidget(
    WidgetsApp.router(
      color: const Color(0xFFFFFFFF),
      routerConfig: router,
      builder: (_, child) => LuminaTheme(child: child!),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _commandDigit(WidgetTester tester, int index) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(_digits[index]);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

void _expectDestination(WidgetTester tester, GoRouter router, int index) {
  expect(router.routeInformationProvider.value.uri.path, '/destination$index');
  expect(find.text('Destination $index'), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void _expectNavigationSemantics(WidgetTester tester, int selected) {
  for (var index = 0; index < DesktopShell.labels.length; index++) {
    final node = tester.getSemantics(find.text(DesktopShell.labels[index]));
    expect(
      node.flagsCollection.isButton,
      isTrue,
      reason: '${DesktopShell.labels[index]} must be a navigation button',
    );
    expect(
      node.flagsCollection.isSelected == Tristate.isTrue,
      index == selected,
      reason: 'Only the current destination is selected',
    );
  }
}

Future<void> _withShell(
  WidgetTester tester,
  Size size,
  Future<void> Function(GoRouter router) body, {
  bool semantics = false,
}) async {
  final previousPlatform = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  final handle = semantics ? tester.ensureSemantics() : null;
  try {
    final router = await _mountShell(tester, size);
    await body(router);
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      handle?.dispose();
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  }
}

void main() {
  for (final layout in {
    'wide': const Size(1180, 800),
    'narrow': const Size(560, 800),
  }.entries) {
    testWidgets('${layout.key}: Cmd+1..8 navigates and announces selection', (
      tester,
    ) async {
      await _withShell(tester, layout.value, (router) async {
        _expectDestination(tester, router, 0);
        _expectNavigationSemantics(tester, 0);
        // Start away from the first branch so Cmd+1 is exercised as a change.
        for (final index in [7, 0, 1, 2, 3, 4, 5, 6, 7]) {
          await _commandDigit(tester, index);
          _expectDestination(tester, router, index);
          _expectNavigationSemantics(tester, index);
        }
      }, semantics: true);
    });

    testWidgets('${layout.key}: Cmd digits preserve a focused editor', (
      tester,
    ) async {
      await _withShell(tester, layout.value, (router) async {
        final editor = find.descendant(
          of: find.byKey(const ValueKey('editor0')),
          matching: find.byType(EditableText),
        );
        await tester.enterText(editor, 'Keep this local draft');
        await tester.pumpAndSettle();
        expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
        for (var index = 0; index < _digits.length; index++) {
          await _commandDigit(tester, index);
          _expectDestination(tester, router, 0);
          expect(
            tester.widget<EditableText>(editor).focusNode.hasFocus,
            isTrue,
          );
          expect(
            tester.widget<EditableText>(editor).controller.text,
            'Keep this local draft',
          );
        }
      });
    });

    testWidgets('${layout.key}: Tab reaches navigation and Enter activates it', (
      tester,
    ) async {
      await _withShell(tester, layout.value, (router) async {
        // Reading order differs between the sidebar and bottom navigation. Both
        // must let normal Tab traversal reach the task destination.
        var reachedTaskButton = false;
        for (var attempt = 0; attempt < 12; attempt++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          final task = tester.getSemantics(find.text(DesktopShell.labels[1]));
          if (task.flagsCollection.isFocused == Tristate.isTrue) {
            reachedTaskButton = true;
            break;
          }
        }
        expect(
          reachedTaskButton,
          isTrue,
          reason: 'Tab must reach the task navigation button',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        _expectDestination(tester, router, 1);
        _expectNavigationSemantics(tester, 1);
      }, semantics: true);
    });

    testWidgets('${layout.key}: authentication route blocks shell shortcuts', (
      tester,
    ) async {
      await _withShell(tester, layout.value, (router) async {
        final authentication = router.push<void>('/auth');
        await tester.pumpAndSettle();
        expect(find.text('Authentication route'), findsOneWidget);
        for (var index = 0; index < _digits.length; index++) {
          await _commandDigit(tester, index);
          expect(find.text('Authentication route'), findsOneWidget);
          expect(router.canPop(), isTrue);
          expect(tester.takeException(), isNull);
        }
        router.pop();
        await authentication;
        await tester.pumpAndSettle();
        _expectDestination(tester, router, 0);
        await _commandDigit(tester, 1);
        _expectDestination(tester, router, 1);
      });
    });

    testWidgets('${layout.key}: root dialog blocks shell shortcuts', (
      tester,
    ) async {
      await _withShell(tester, layout.value, (router) async {
        final dialog = showLuminaDialog<void>(
          context: tester.element(find.byType(DesktopShell)),
          title: 'Keep this dialog open',
          content: const Text('Modal content'),
        );
        await tester.pumpAndSettle();
        for (var index = 0; index < _digits.length; index++) {
          await _commandDigit(tester, index);
          expect(find.text('Keep this dialog open'), findsOneWidget);
          expect(
            router.routeInformationProvider.value.uri.path,
            '/destination0',
          );
          expect(tester.takeException(), isNull);
        }
        Navigator.of(
          tester.element(find.byType(DesktopShell)),
          rootNavigator: true,
        ).pop();
        await dialog;
        await tester.pumpAndSettle();
        _expectDestination(tester, router, 0);
        await _commandDigit(tester, 1);
        _expectDestination(tester, router, 1);
      });
    });

    testWidgets(
      '${layout.key}: unmounted shell does not intercept Cmd digits',
      (tester) async {
        await _withShell(tester, layout.value, (router) async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          expect(find.byType(DesktopShell), findsNothing);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          try {
            for (final digit in _digits) {
              final handled = await tester.sendKeyEvent(digit);
              expect(
                handled,
                isFalse,
                reason: 'Disposed shell must not consume navigation keys',
              );
            }
          } finally {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          }
          await tester.pumpAndSettle();
          expect(
            router.routeInformationProvider.value.uri.path,
            '/destination0',
          );
          expect(tester.takeException(), isNull);
        });
      },
    );
  }
}
