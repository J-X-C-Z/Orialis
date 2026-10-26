import 'package:flutter/material.dart' show Chip, Material, MaterialApp;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/devices/application/device_center_controller.dart';
import 'package:orialis_mobile/features/devices/data/device_data_source.dart';
import 'package:orialis_mobile/features/devices/domain/device.dart';
import 'package:orialis_mobile/features/devices/presentation/device_center_page.dart';
import 'package:orialis_mobile/features/memory/data/memory_repository.dart';
import 'package:orialis_mobile/features/memory/domain/memory_record.dart';
import 'package:orialis_mobile/features/memory/presentation/memory_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _show(WidgetTester tester, Widget page, bool? enabled) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => LuminaTheme(
        data: const LuminaThemeData(neumorphic: true, neumorphicGlass: true),
        child: enabled == null
            ? child!
            : LuminaGlassTitleScope(enabled: enabled, child: child!),
      ),
      home: Material(child: page),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectHeading(WidgetTester tester, String title, bool glass) {
  final text = find.text(title);
  expect(text, findsOneWidget);
  expect(
    find.ancestor(of: text, matching: find.byType(LuminaCardHeader)),
    glass ? findsOneWidget : findsNothing,
  );
  expect(
    find.ancestor(
      of: text,
      matching: find.byKey(const ValueKey('lumina-glass-card-title')),
    ),
    glass ? findsOneWidget : findsNothing,
  );
  if (!glass) expect(tester.widget<Text>(text).style, isNull);
}

void main() {
  for (final enabled in <bool?>[null, false, true]) {
    for (final videoStatus in ['analyzed', 'unavailable']) {
      testWidgets(
        'memory detail headings inherit root scope $enabled ($videoStatus)',
        (tester) async {
          final repository = _MemoryRepository(videoStatus: videoStatus);
          addTearDown(repository.dispose);
          await _show(tester, MemoryPage(repository: repository), enabled);
          expect(find.byType(LuminaCardHeader), findsNothing);
          expect(find.text('测试收藏'), findsOneWidget);

          await tester.tap(find.text('测试收藏'));
          await tester.pumpAndSettle();
          final scrollable = find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ).first;
          for (final title in [
            '内容摘要',
            '视频理解',
            '我的笔记',
            '捕获到的链接',
            '原始截图',
            '原始内容',
          ]) {
            await tester.scrollUntilVisible(
              find.text(title),
              200,
              scrollable: scrollable,
            );
            _expectHeading(tester, title, enabled == true);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('device card names inherit root scope $enabled', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _show(
        tester,
        ProviderScope(
          overrides: [
            deviceDataSourceProvider.overrideWithValue(_DeviceSource()),
          ],
          child: const DeviceCenterPage(),
        ),
        enabled,
      );
      for (final title in ['手机详情名称', '电脑']) {
        expect(find.text(title), findsOneWidget);
        expect(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(LuminaCardHeader),
          ),
          enabled == true ? findsOneWidget : findsNothing,
        );
        expect(
          find.ancestor(
            of: find.text(title),
            matching: find.byKey(const ValueKey('lumina-glass-card-title')),
          ),
          enabled == true ? findsOneWidget : findsNothing,
        );
        if (enabled != true) {
          final context = tester.element(find.text(title));
          expect(
            tester.widget<Text>(find.text(title)).style,
            LuminaTheme.of(context).textTheme.titleMedium,
          );
        }
      }
      expect(find.text('手机列表名称'), findsNothing);
      expect(find.byType(Chip), findsOneWidget);
      expect(find.text('android · 在线'), findsOneWidget);
      expect(find.text('desktop · 离线'), findsOneWidget);
      expect(find.text('tasks.read'), findsOneWidget);
      expect(find.text('切换到此设备'), findsOneWidget);
      expect(find.text('撤销'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }
}

class _MemoryRepository extends MemoryRepository {
  _MemoryRepository({required String videoStatus})
    : record = MemoryRecord(
        id: 'glass-test',
        createdAt: DateTime.utc(2026, 10, 26),
        sourcePackage: 'browser',
        sourceLabel: '浏览器',
        visibleText: '原始文字',
        urls: const ['https://example.com'],
        title: '测试收藏',
        summary: '摘要正文',
        notes: '笔记正文',
        imagePath: '/missing-glass-test.png',
        videoStatus: videoStatus,
        videoSummary: '视频正文',
        videoError: '视频暂不可用',
      );

  final MemoryRecord record;

  @override
  Future<MemoryStatus> status() async => const MemoryStatus(supported: true);
  @override
  Future<List<MemoryRecord>> list() async => [record];
  @override
  Future<MemoryRecord> read(String id) async => record;
}

class _DeviceSource extends Fake implements DeviceDataSource {
  static const devices = [
    ConnectedDevice(
      deviceId: 'phone',
      displayName: '手机列表名称',
      platform: 'android',
      status: DeviceStatus.online,
      capabilities: [
        DeviceCapability(name: 'tasks.read', available: true, granted: true),
      ],
    ),
    ConnectedDevice(
      deviceId: 'desktop',
      displayName: '电脑',
      platform: 'desktop',
      status: DeviceStatus.offline,
      capabilities: [],
    ),
  ];

  @override
  Future<List<ConnectedDevice>> listDevices() async => devices;
  @override
  Future<ConnectedDevice> getDevice(String deviceId) async =>
      devices.first.copyWith(displayName: '手机详情名称');
  @override
  Future<List<DeviceCapability>> getCapabilities(String deviceId) async =>
      devices.first.capabilities;
}
