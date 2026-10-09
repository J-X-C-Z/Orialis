import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/app/app.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/web_services/web_service.dart';
import 'package:orialis_mobile/features/web_services/web_service_launcher.dart';
import 'package:orialis_mobile/features/web_services/web_services_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _showServices(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1180, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [desktopModeProvider.overrideWithValue(true)],
      child: WidgetsApp(
        color: const Color(0xFFFFFFFF),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        home: const WebServicesPage(),
        builder: (_, child) => LuminaTheme(child: child!),
      ),
    ),
  );
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const paperclip = WebService(
    id: 'paperclip',
    name: 'Paperclip',
    description: '项目与 Agent 管理',
    url: 'http://127.0.0.1:3100/ORI/dashboard',
    icon: 'paperclip',
  );

  test(
    'an already reachable service does not start another background process',
    () async {
      final starts = <String>[];
      final checks = <Uri>[];
      final launcher = WebServiceLauncher(
        checkReady: (uri) async {
          checks.add(uri);
          return true;
        },
        startService: (id) async {
          starts.add(id);
        },
      );
      await launcher.ensureReady(paperclip);
      expect(checks, [Uri.parse(paperclip.url)]);
      expect(starts, isEmpty);
    },
  );

  test(
    'a cold local service starts its own ID and waits for readiness',
    () async {
      final events = <String>[];
      var started = false;
      final launcher = WebServiceLauncher(
        checkReady: (uri) async {
          events.add('check:${uri.port}');
          return started;
        },
        startService: (id) async {
          events.add('start:$id');
          started = true;
        },
      );
      await launcher.ensureReady(paperclip);
      expect(events, ['check:3100', 'start:paperclip', 'check:3100']);
    },
  );

  test(
    'unreachable custom remote and local ports do not start local services',
    () async {
      final starts = <String>[];
      final launcher = WebServiceLauncher(
        checkReady: (_) async => false,
        startService: (id) async {
          starts.add(id);
        },
      );
      for (final url in [
        'https://paperclip.example.com',
        'http://127.0.0.1:9999',
      ]) {
        await expectLater(
          launcher.ensureReady(paperclip.withUrl(url)),
          throwsStateError,
        );
      }
      expect(starts, isEmpty);
    },
  );

  test(
    'startup failure propagates without reporting the service ready',
    () async {
      final failure = StateError('SSH tunnel could not start');
      var checks = 0;
      final launcher = WebServiceLauncher(
        checkReady: (_) async {
          checks += 1;
          return false;
        },
        startService: (_) async => throw failure,
      );
      await expectLater(
        launcher.ensureReady(paperclip),
        throwsA(same(failure)),
      );
      expect(checks, 1);
    },
  );

  test(
    'desktop services load the three configured local Web UI addresses',
    () async {
      final store = WebServiceStore(await SharedPreferences.getInstance());
      final services = await store.load(desktop: true);
      expect(
        {for (final service in services) service.id: service.url},
        {
          'paperclip': 'http://127.0.0.1:3100/ORI/dashboard',
          'server-monitor': 'http://127.0.0.1:8876',
          'hindsight': 'http://127.0.0.1:29999/dashboard',
        },
      );
    },
  );

  test(
    'saved URL survives a new store and leaves other services unchanged',
    () async {
      final store = WebServiceStore(await SharedPreferences.getInstance());
      await store.saveUrl(
        'server-monitor',
        '  https://monitor.example.com/view?host=desktop  ',
      );
      final reloaded = await WebServiceStore(
        await SharedPreferences.getInstance(),
      ).load(desktop: true);
      expect(
        reloaded.singleWhere((s) => s.id == 'server-monitor').url,
        'https://monitor.example.com/view?host=desktop',
      );
      expect(
        reloaded.singleWhere((s) => s.id == 'paperclip').url,
        'http://127.0.0.1:3100/ORI/dashboard',
      );
    },
  );

  test(
    'invalid URLs and embedded credentials cannot overwrite a saved address',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = WebServiceStore(preferences);
      await store.saveUrl('server-monitor', 'http://127.0.0.1:8876');
      for (final invalid in [
        '',
        '127.0.0.1:8876',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'https://',
        'https://user:password@example.com',
      ]) {
        expect(WebService.parseUrl(invalid), isNull, reason: invalid);
        await expectLater(
          store.saveUrl('server-monitor', invalid),
          throwsFormatException,
        );
        expect(
          preferences.getString(WebServiceStore.key('server-monitor')),
          'http://127.0.0.1:8876',
        );
      }
    },
  );

  testWidgets(
    'desktop list offers all services and persists an edited address',
    (tester) async {
      await _showServices(tester);
      expect(find.text('Web 服务'), findsOneWidget);
      expect(find.text('Paperclip'), findsOneWidget);
      expect(find.text('服务器监控'), findsOneWidget);
      expect(find.text('Hindsight'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is LuminaIconButton && widget.tooltip == '修改 服务器监控 地址',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('服务器监控 地址'), findsOneWidget);
      await tester.enterText(
        find.byType(LuminaTextField),
        'http://127.0.0.1:9988',
      );
      await tester.tap(find.text('保存'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('http://127.0.0.1:9988'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          WebServiceStore.key('server-monitor'),
        ),
        'http://127.0.0.1:9988',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
