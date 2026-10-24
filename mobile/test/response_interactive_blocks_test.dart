import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_interactive_schema.dart';
import 'package:orialis_mobile/features/chat/presentation/response_interactive_blocks.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _Picker extends FilePickerPlatform {
  Uint8List? saved;
  bool fail = false;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (fail) throw StateError('save failed');
    saved = bytes;
    return Uri.file('/tmp/table.csv');
  }
}

class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    expect(options.mode, PreferredLaunchMode.externalApplication);
    opened.add(url);
    return true;
  }
}

Map<String, dynamic> _form() => {
  'type': 'form',
  'prompt': '按这些条件安排学习',
  'items': [
    {'id': 'topic', 'label': '主题', 'kind': 'text', 'required': true},
    {'id': 'date', 'label': '日期', 'kind': 'date', 'required': true},
    {
      'id': 'subject',
      'label': '科目',
      'kind': 'select',
      'options': ['数学', '英语'],
    },
    {
      'id': 'tools',
      'label': '材料',
      'kind': 'multiselect',
      'options': ['教材', '习题'],
    },
    {
      'id': 'hours',
      'label': '小时',
      'kind': 'slider',
      'min': 1,
      'max': 4,
      'value': 2,
    },
  ],
};

Map<String, dynamic> _table() => {
  'type': 'table',
  'columns': ['姓名', '分数'],
  'items': [
    {
      'label': 'Alice',
      'cells': ['Alice', 10],
    },
    {
      'label': 'Bob',
      'cells': ['Bob', 2],
    },
  ],
};

Widget _host(
  Map<String, dynamic> data, {
  ValueChanged<String>? onPromptSelected,
}) => MaterialApp(
  home: LuminaTheme(
    highPerformanceMode: true,
    child: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 240,
            child: ResponseInteractiveBlock(
              data: data,
              onPromptSelected: onPromptSelected,
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bounded interactive schemas accept all four shapes', () {
    for (final value in [
      _form(),
      _table(),
      {
        'type': 'sources',
        'items': [
          {
            'label': '官方资料',
            'url': 'https://example.com/docs',
            'excerpt': '原文摘录',
          },
        ],
      },
      {
        'type': 'diff',
        'items': [
          {'label': '修改', 'before': '', 'after': 'hello'},
        ],
      },
    ]) {
      expect(validateInteractiveResponseBlock(value), isTrue, reason: '$value');
    }
  });

  test('rejects duplicate ids, impossible dates, foreign options and malformed cells', () {
    final invalid = <Map<String, dynamic>>[
      {
        ..._form(),
        'items': [
          {'id': 'x', 'label': '一', 'kind': 'text'},
          {'id': 'x', 'label': '二', 'kind': 'text'},
        ],
      },
      {
        ..._form(),
        'items': [
          {'id': 'x', 'label': '日', 'kind': 'date', 'value': '2026-02-30'},
        ],
      },
      {
        ..._form(),
        'items': [
          {
            'id': 'x',
            'label': '选项',
            'kind': 'select',
            'options': ['A'],
            'value': 'B',
          },
        ],
      },
      {
        ..._form(),
        'items': [
          {
            'id': 'x',
            'label': '多选',
            'kind': 'multiselect',
            'options': ['A'],
            'value': ['B'],
          },
        ],
      },
      {
        ..._form(),
        'items': [
          {'id': 'x', 'label': '范围', 'kind': 'slider', 'min': 1, 'max': 1},
        ],
      },
      {
        ..._form(),
        'items': [
          {
            'id': 'x',
            'label': '范围',
            'kind': 'slider',
            'min': 1,
            'max': 2,
            'value': 3,
          },
        ],
      },
      {
        ..._table(),
        'items': [
          {
            'label': 'A',
            'cells': ['one cell'],
          },
        ],
      },
      {
        ..._table(),
        'items': [
          {
            'label': 'A',
            'cells': ['A', double.infinity],
          },
        ],
      },
      {
        'type': 'diff',
        'items': [
          {'label': 'A', 'before': 'x' * 4001, 'after': ''},
        ],
      },
    ];
    for (final value in invalid) {
      expect(
        validateInteractiveResponseBlock(value),
        isFalse,
        reason: '$value',
      );
    }
    for (final url in [
      'javascript:alert(1)',
      'file:///tmp/a',
      'https://user:pass@example.com',
      'https://',
      'https://example.com/a b',
    ]) {
      expect(
        validateInteractiveResponseBlock({
          'type': 'sources',
          'items': [
            {'label': 'A', 'url': url},
          ],
        }),
        isFalse,
      );
    }
    expect(responseDateIsValid('2024-02-29'), isTrue);
    expect(responseDateIsValid('2025-02-29'), isFalse);
  });

  test(
    'CSV quotes embedded delimiters and prevents string formula execution',
    () {
      expect(
        responseTableCsv(
          ['列'],
          [
            ['=1+1'],
            [' a,"b"'],
            [-2],
          ],
        ),
        '"列"\r\n"\'=1+1"\r\n" a,""b"""\r\n"-2"',
      );
      expect(
        responseTableCsv(
          ['列'],
          [
            ['  @SUM(A1)'],
          ],
        ),
        contains("'  @SUM(A1)"),
      );
    },
  );

  testWidgets(
    'all form fields validate and fill the draft only on explicit submit',
    (tester) async {
      final prompts = <String>[];
      final data = _form();
      await tester.pumpWidget(_host(data, onPromptSelected: prompts.add));
      await tester.ensureVisible(find.text('填入输入框'));
      await tester.tap(find.text('填入输入框'));
      await tester.pump();
      expect(find.text('请填写主题'), findsOneWidget);
      expect(prompts, isEmpty);
      final topic = find.descendant(
        of: find.byKey(const ValueKey('field-topic')),
        matching: find.byType(EditableText),
      );
      final date = find.descendant(
        of: find.byKey(const ValueKey('field-date')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(topic, '复习导数');
      await tester.enterText(date, '2026-02-30');
      await tester.ensureVisible(find.text('填入输入框'));
      await tester.tap(find.text('填入输入框'));
      await tester.pump();
      expect(find.textContaining('请使用有效日期'), findsOneWidget);
      expect(prompts, isEmpty);
      await tester.enterText(date, '2026-10-25');
      await tester.ensureVisible(find.text('数学'));
      await tester.tap(find.text('数学'));
      await tester.ensureVisible(find.text('教材'));
      await tester.tap(find.text('教材'));
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('slider-hours')),
      );
      slider.onChanged!(3);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(prompts, isEmpty);
      await tester.ensureVisible(find.text('填入输入框'));
      await tester.tap(find.text('填入输入框'));
      await tester.pump();
      expect(
        prompts.single,
        '按这些条件安排学习\n主题：复习导数\n日期：2026-10-25\n科目：数学\n材料：教材\n小时：3.0',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'streaming disables submission and changed data resets form values',
    (tester) async {
      await tester.pumpWidget(_host(_form()));
      final submit = tester.widget<LuminaButton>(
        find.ancestor(
          of: find.text('填入输入框'),
          matching: find.byType(LuminaButton),
        ),
      );
      expect(submit.onPressed, isNull);
      final field = find.descendant(
        of: find.byKey(const ValueKey('field-topic')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field, 'temporary');
      final changed = _form();
      changed['items'][0]['value'] = '新主题';
      await tester.pumpWidget(_host(changed));
      expect(tester.widget<EditableText>(field).controller.text, '新主题');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('table sorts numerically, filters and exports the visible CSV', (
    tester,
  ) async {
    String? clipboard;
    final picker = _Picker();
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(_host(_table()));
    final table = tester.widget<DataTable>(find.byType(DataTable));
    table.columns.last.onSort!(2, true);
    await tester.pump();
    expect(tester.widget<DataTable>(find.byType(DataTable)).sortColumnIndex, 2);
    await tester.ensureVisible(find.text('复制 CSV'));
    await tester.tap(find.text('复制 CSV'));
    await tester.pump();
    expect(clipboard, '"姓名","分数"\r\n"Bob","2"\r\n"Alice","10"');
    await tester.enterText(find.byType(EditableText), 'Alice');
    await tester.pump();
    expect(find.text('显示 1 / 2 行；点击列名排序'), findsOneWidget);
    await tester.ensureVisible(find.text('导出 CSV'));
    await tester.tap(find.text('导出 CSV'));
    await tester.pumpAndSettle();
    expect(picker.saved!.take(3), [0xef, 0xbb, 0xbf]);
    expect(utf8.decode(picker.saved!), '"姓名","分数"\r\n"Alice","10"');
    expect(find.text('表格已导出'), findsOneWidget);
    expect(tester.takeException(), isNull);
    picker.fail = true;
    await tester.tap(find.text('导出 CSV'));
    await tester.pumpAndSettle();
    expect(find.text('导出失败，请重试或复制 CSV'), findsOneWidget);
  });

  testWidgets(
    'table rows open full readable details on a narrow large-text screen',
    (tester) async {
      tester.view.physicalSize = const Size(240, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final detail = '这是一段需要展开才能完整阅读的说明。' * 12;
      final data = _table();
      data['columns'] = ['说明', '分数'];
      data['items'][0]['cells'][0] = detail;
      await tester.pumpWidget(_host(data));
      await tester.ensureVisible(find.text('展开行').first);
      await tester.tap(find.text('展开行').first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text(detail)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('说明')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭详情'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source excerpts expand and URLs open only when tapped', (
    tester,
  ) async {
    final launcher = _Launcher();
    final original = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);
    await tester.pumpWidget(
      _host({
        'type': 'sources',
        'items': [
          {
            'label': '官方资料',
            'url': 'https://example.com/docs',
            'sourceId': 'doc-1',
            'excerpt': '原文摘录',
          },
        ],
      }),
    );
    expect(launcher.opened, isEmpty);
    expect(find.text('原文摘录'), findsNothing);
    await tester.tap(find.text('查看摘录'));
    await tester.pump();
    expect(find.text('原文摘录'), findsOneWidget);
    await tester.tap(find.text('打开来源'));
    await tester.pumpAndSettle();
    expect(launcher.opened, ['https://example.com/docs']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'diff exposes explicit additions and removals only when expanded',
    (tester) async {
      await tester.pumpWidget(
        _host({
          'type': 'diff',
          'items': [
            {
              'label': '修正输出',
              'before': 'same\nold\nend',
              'after': 'same\nnew\nend',
            },
          ],
        }),
      );
      expect(find.text('− old'), findsNothing);
      await tester.tap(find.text('展开对比'));
      await tester.pump();
      expect(find.text('− old'), findsOneWidget);
      expect(find.text('+ new'), findsOneWidget);
      expect(find.text('  same'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
