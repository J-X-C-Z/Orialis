import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/core/config/app_config.dart';
import 'package:orialis_mobile/core/database/app_database.dart';
import 'package:orialis_mobile/features/system_integration/system_integration_controller.dart';
import 'package:orialis_mobile/features/system_integration/system_widget_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('widget catalog keeps the native kind and size contract', () {
    final widgets = systemWidgetCatalog
        .expand((group) => group.widgets)
        .toList();

    expect(systemWidgetCatalog.map((group) => group.title), [
      '今日',
      '任务',
      '日程',
      '快捷入口',
    ]);
    expect(widgets.map((widget) => widget.kind), [
      'today_compact',
      'today',
      'today_expanded',
      'tasks_compact',
      'tasks',
      'tasks_expanded',
      'agenda',
      'agenda_expanded',
      'month',
      'shortcuts_compact',
      'shortcuts',
    ]);
    expect(widgets.map((widget) => widget.size), [
      '2×2',
      '4×2',
      '4×4',
      '2×2',
      '4×2',
      '4×4',
      '4×2',
      '4×4',
      '4×4',
      '2×1',
      '4×1',
    ]);
    expect(widgets.map((widget) => widget.kind).toSet(), hasLength(11));
    expect(widgets.where((widget) => widget.kind == 'today'), hasLength(1));
  });

  test('pin request sends the selected kind to the native bridge', () async {
    final database = AppDatabase(executor: AppDatabase.inMemoryExecutor());
    const channel = MethodChannel('test/system-widget-catalog');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    final controller = SystemIntegrationController(
      database: database,
      config: AppConfig(),
      channel: channel,
      supported: true,
    );

    expect(await controller.requestPinWidget(), isTrue);
    expect(await controller.requestPinWidget(kind: 'month'), isTrue);
    expect(calls.map((call) => call.method), [
      'requestPinWidget',
      'requestPinWidget',
    ]);
    expect(calls.map((call) => call.arguments), [
      {'kind': 'today'},
      {'kind': 'month'},
    ]);

    await controller.dispose();
    await database.close();
  });
}
