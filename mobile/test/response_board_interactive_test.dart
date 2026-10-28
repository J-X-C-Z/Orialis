import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;
import 'package:orialis_mobile/features/chat/domain/response_interactive_schema.dart';
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/response_interactive_blocks.dart';
import 'package:orialis_mobile/features/chat/presentation/response_ui_view.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _Picker extends FilePickerPlatform {
  Uint8List? saved;
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
    saved = bytes;
    return Uri.file('/tmp/board.csv');
  }
}

class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

Widget _host(Widget child, {double width = 240, double textScale = 2}) =>
    MaterialApp(
      home: LuminaTheme(
        highPerformanceMode: true,
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    );

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _editor(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);

DataTable _tableWidget(WidgetTester tester) =>
    tester.widget<DataTable>(find.byType(DataTable));

List<String> _cells(WidgetTester tester, int column) => [
  for (final row in _tableWidget(tester).rows)
    tester
        .widget<Text>(
          find.descendant(
            of: find.byWidget(row.cells[column + 1].child),
            matching: find.byType(Text),
          ),
        )
        .data!,
];

Future<void> _pageSize(WidgetTester tester, int size) async {
  tester
      .widget<DropdownButton<int>>(
        find.byKey(const ValueKey('table-page-size')),
      )
      .onChanged!(size);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _table() => {
  'type': 'table',
  'columns': ['姓名', '分数'],
  'items': [
    for (var i = 0; i < 12; i++)
      {
        'label': 'record-$i',
        'cells': [
          '${i < 8 ? 'match' : 'other'}-$i',
          [10, 2, 5, 2, 11, 7, 1, 4, 12, 8, 3, 6][i],
        ],
      },
  ],
};

Map<String, dynamic> _accordion(Object? content) => {
  'type': 'accordion',
  'items': [
    {'label': '条目', 'content': content},
  ],
};

String _document(List<Map<String, dynamic>> blocks) =>
    jsonEncode({'version': 1, 'fallback': '文本摘要', 'blocks': blocks});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'accordion strictly validates content and preserves document limits',
    () {
      expect(interactiveResponseTypes, contains('accordion'));
      for (final content in [
        '',
        ' ',
        null,
        42,
        ['text'],
        '字' * 4001,
        '😀' * 4001,
      ]) {
        expect(validateInteractiveResponseBlock(_accordion(content)), isFalse);
        expect(
          ResponseUiDocument.parse(_document([_accordion(content)])),
          isNull,
        );
      }
      for (final content in ['字' * 4000, '😀' * 4000]) {
        expect(validateInteractiveResponseBlock(_accordion(content)), isTrue);
        final parsed = ResponseUiDocument.parse(
          _document([_accordion(content)]),
        );
        expect(parsed!.version, 1);
        expect(parsed.blocks.single.type, 'accordion');
        expect(parsed.blocks.single.data['items'][0]['content'], content);
      }
      expect(
        validateInteractiveResponseBlock({
          'type': 'accordion',
          'items': [
            {'label': 'missing'},
          ],
        }),
        isFalse,
      );
      expect(
        validateInteractiveResponseBlock({'type': 'accordion', 'items': []}),
        isFalse,
      );
      expect(
        ResponseUiDocument.parse(
          _document(List.generate(12, (_) => _accordion('x'))),
        ),
        isNotNull,
      );
      expect(
        ResponseUiDocument.parse(
          _document(List.generate(13, (_) => _accordion('x'))),
        ),
        isNull,
      );
      final oversized = _document(
        List.generate(3, (_) => _accordion('字' * 4000)),
      );
      expect(oversized.length, lessThan(32768));
      expect(utf8.encode(oversized).length, greaterThan(32768));
      expect(ResponseUiDocument.parse(oversized), isNull);
    },
  );

  testWidgets('pagination, search, stable numeric sort and full CSV agree', (
    tester,
  ) async {
    String? copied;
    final picker = _Picker();
    final oldPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = oldPicker);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = call.arguments['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final data = _table();
    await tester.pumpWidget(
      _host(ResponseInteractiveBlock(data: data), width: 800, textScale: 1),
    );
    expect(find.byKey(const ValueKey('table-search')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('table-tools')));
    expect(find.byKey(const ValueKey('table-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-sort-column')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-page-size')), findsOneWidget);
    expect(find.text('复制 CSV'), findsOneWidget);
    expect(find.text('导出 CSV'), findsOneWidget);
    expect(_tableWidget(tester).rows.length, 5);
    expect(
      tester.widget<LuminaButton>(
        find.byKey(const ValueKey('table-previous-page')),
      ),
      isA<LuminaButton>(),
    );
    expect(
      tester.widget<LuminaButton>(
        find.byKey(const ValueKey('table-next-page')),
      ),
      isA<LuminaButton>(),
    );
    final footer = find
        .ancestor(
          of: find.byKey(const ValueKey('table-page-status')),
          matching: find.byType(Row),
        )
        .first;
    expect(
      find.descendant(
        of: footer,
        matching: find.byKey(const ValueKey('table-previous-page')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: footer,
        matching: find.byKey(const ValueKey('table-next-page')),
      ),
      findsOneWidget,
    );
    expect(_cells(tester, 0).first, 'match-0');
    await _tap(tester, find.byKey(const ValueKey('table-next-page')));
    expect(_cells(tester, 0).first, 'match-5');
    await _tap(tester, find.byKey(const ValueKey('table-next-page')));
    expect(_tableWidget(tester).rows.length, 2);
    expect(
      tester
          .widget<LuminaButton>(find.byKey(const ValueKey('table-next-page')))
          .onPressed,
      isNull,
    );
    await _pageSize(tester, 10);
    expect(_tableWidget(tester).rows.length, 10);
    expect(_cells(tester, 0).first, 'match-0');
    await _pageSize(tester, 0);
    expect(_tableWidget(tester).rows.length, 12);
    expect(find.byKey(const ValueKey('table-page-status')), findsNothing);
    await _pageSize(tester, 5);
    await _tap(tester, find.byKey(const ValueKey('table-next-page')));
    await tester.enterText(_editor('table-search'), 'MATCH');
    await tester.pumpAndSettle();
    expect(find.text('8 / 12 条匹配'), findsOneWidget);
    expect(_cells(tester, 0).first, 'match-0');
    _tableWidget(tester).columns[2].onSort!(2, true);
    await tester.pumpAndSettle();
    expect(_tableWidget(tester).sortColumnIndex, 2);
    expect(_cells(tester, 0), [
      'match-6',
      'match-1',
      'match-3',
      'match-7',
      'match-2',
    ]);
    expect(find.textContaining('升序'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('table-next-page')));
    expect(_tableWidget(tester).rows.length, 3);
    await _tap(tester, find.text('复制 CSV'));
    final expected = responseTableCsv(
      ['姓名', '分数'],
      [
        for (final i in [6, 1, 3, 7, 2, 5, 0, 4])
          (data['items'][i]['cells'] as List).cast<Object?>(),
      ],
    );
    expect(copied, expected);
    expect(copied!.split('\r\n').length, 9);
    await _tap(tester, find.text('导出 CSV'));
    expect(picker.saved!.take(3), [0xef, 0xbb, 0xbf]);
    expect(utf8.decode(picker.saved!), expected);
    _tableWidget(tester).columns[2].onSort!(2, false);
    await tester.pumpAndSettle();
    expect(_cells(tester, 0), [
      'match-4',
      'match-0',
      'match-5',
      'match-2',
      'match-7',
    ]);
    expect(find.textContaining('降序'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('table-clear-sort')));
    expect(_tableWidget(tester).sortColumnIndex, isNull);
    expect(_cells(tester, 0).first, 'match-0');
    await tester.enterText(_editor('table-search'), 'not-found');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('table-empty')), findsOneWidget);
    expect(_tableWidget(tester).rows, isEmpty);
    await _tap(tester, find.byKey(const ValueKey('table-clear-search')));
    expect(_cells(tester, 0).first, 'match-0');
    expect(find.byKey(const ValueKey('table-empty')), findsNothing);
    expect(find.text('12 条记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow table summary opens selectable full details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = _table();
    final detail = '很长的完整说明。' * 80;
    data['items'][0]['cells'][0] = detail;
    await tester.pumpWidget(
      _host(ResponseInteractiveBlock(data: data), width: 240),
    );
    expect(find.byType(DataTable), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('table-row-0')), findsOneWidget);
    expect(
      tester.widget<LuminaIconButton>(
        find.byKey(const ValueKey('table-next-page')),
      ),
      isA<LuminaIconButton>(),
    );
    expect(
      tester.widget<LuminaIconButton>(
        find.byKey(const ValueKey('table-previous-page')),
      ),
      isA<LuminaIconButton>(),
    );
    final compactFooter = find
        .ancestor(
          of: find.byKey(const ValueKey('table-page-status')),
          matching: find.byType(Row),
        )
        .first;
    expect(
      find.descendant(
        of: compactFooter,
        matching: find.byKey(const ValueKey('table-previous-page')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: compactFooter,
        matching: find.byKey(const ValueKey('table-next-page')),
      ),
      findsOneWidget,
    );
    await _tap(tester, find.byKey(const ValueKey('table-row-0')));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(detail),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(LuminaSelectableText),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
    await _tap(tester, find.text('关闭详情'));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'form reset restores every original value without touching composer draft',
    (tester) async {
      final data = <String, dynamic>{
        'type': 'form',
        'items': [
          {
            'id': 'topic',
            'label': '主题',
            'kind': 'text',
            'required': true,
            'value': '原主题',
          },
          {'id': 'date', 'label': '日期', 'kind': 'date', 'value': '2026-10-25'},
          {
            'id': 'mode',
            'label': '方式',
            'kind': 'select',
            'options': ['原方式', '新方式'],
            'value': '原方式',
          },
          {
            'id': 'tools',
            'label': '材料',
            'kind': 'multiselect',
            'options': ['教材', '习题'],
            'value': ['教材'],
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
      var draft = '已经存在的输入框草稿';
      var submitted = 0;
      await tester.pumpWidget(
        _host(
          ResponseInteractiveBlock(
            data: data,
            onPromptSelected: (value) {
              draft = value;
              submitted++;
            },
          ),
        ),
      );
      await tester.enterText(_editor('field-topic'), '临时主题');
      await tester.enterText(_editor('field-date'), '2026-12-01');
      await _tap(tester, find.text('新方式'));
      await _tap(tester, find.text('习题'));
      tester
          .widget<Slider>(find.byKey(const ValueKey('slider-hours')))
          .onChanged!(4);
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('form-reset')));
      expect(draft, '已经存在的输入框草稿');
      expect(submitted, 0);
      expect(
        tester.widget<EditableText>(_editor('field-topic')).controller.text,
        '原主题',
      );
      expect(
        tester.widget<EditableText>(_editor('field-date')).controller.text,
        '2026-10-25',
      );
      expect(
        tester.widget<Slider>(find.byKey(const ValueKey('slider-hours'))).value,
        2,
      );
      bool selected(String label) => tester
          .widget<LuminaButton>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(LuminaButton),
            ),
          )
          .primary;
      expect(selected('原方式'), isTrue);
      expect(selected('新方式'), isFalse);
      expect(selected('教材'), isTrue);
      expect(selected('习题'), isFalse);
      expect(data['items'][3]['value'], ['教材']);
      await _tap(tester, find.text('填入输入框'));
      expect(submitted, 1);
      expect(draft, contains('主题：原主题'));
      expect(draft, contains('日期：2026-10-25'));
      expect(draft, contains('方式：原方式'));
      expect(draft, contains('材料：教材'));
      expect(draft, contains('小时：2.0'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'required and date errors belong to their fields and clear on reset',
    (tester) async {
      await tester.pumpWidget(
        _host(
          ResponseInteractiveBlock(
            data: {
              'type': 'form',
              'items': [
                {'id': 'name', 'label': '姓名', 'kind': 'text', 'required': true},
                {'id': 'date', 'label': '日期', 'kind': 'date'},
              ],
            },
            onPromptSelected: (_) => fail('invalid form must not fill draft'),
          ),
        ),
      );
      expect(find.text('必填'), findsOneWidget);
      expect(find.text('选填'), findsOneWidget);
      await tester.enterText(_editor('field-date'), '2026-02-30');
      await _tap(tester, find.text('填入输入框'));
      expect(find.byKey(const ValueKey('form-error-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('form-error-date')), findsOneWidget);
      await tester.enterText(_editor('field-name'), '小明');
      await tester.pump();
      expect(find.byKey(const ValueKey('form-error-name')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('form-reset')));
      expect(find.byKey(const ValueKey('form-error-date')), findsNothing);
      expect(
        tester.widget<EditableText>(_editor('field-name')).controller.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'main response entry dispatches independent selectable accordion items',
    (tester) async {
      final document = ResponseUiDocument.parse(
        _document([
          {
            'type': 'accordion',
            'items': [
              {'label': '第一项', 'content': '第一段正文'},
              {'label': '第二项', 'content': '第二段正文'},
            ],
          },
        ]),
      )!;
      await tester.pumpWidget(_host(ResponseUiView(document: document)));
      expect(find.byType(ResponseInteractiveBlock), findsOneWidget);
      expect(find.text('第一段正文'), findsNothing);
      expect(find.text('第二段正文'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('accordion-toggle-0')));
      await _tap(tester, find.byKey(const ValueKey('accordion-toggle-1')));
      expect(find.byKey(const ValueKey('accordion-content-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('accordion-content-1')), findsOneWidget);
      expect(
        tester.widget(find.byKey(const ValueKey('accordion-content-0'))),
        isA<LuminaSelectableText>(),
      );
      await _tap(tester, find.byKey(const ValueKey('accordion-toggle-0')));
      expect(find.text('第一段正文'), findsNothing);
      expect(find.text('第二段正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source domain is visible and opening requires an explicit tap', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
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
    final launcher = _Launcher();
    final oldLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = oldLauncher);
    await tester.pumpWidget(
      _host(
        const ResponseInteractiveBlock(
          data: {
            'type': 'sources',
            'items': [
              {
                'label': '官方说明',
                'url': 'https://example.com/docs',
                'sourceId': 'doc-1',
                'excerpt': '完整摘录',
              },
            ],
          },
        ),
      ),
    );
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('https://example.com/docs'), findsOneWidget);
    expect(find.text('来源编号：doc-1'), findsOneWidget);
    expect(launcher.opened, isEmpty);
    expect(copied, isNull);
    expect(find.text('查看摘录').hitTestable(), findsOneWidget);
    await tester.tap(find.text('查看摘录'));
    await tester.pump();
    expect(find.text('完整摘录'), findsOneWidget);
    expect(launcher.opened, isEmpty);
    expect(find.text('复制地址').hitTestable(), findsOneWidget);
    await tester.tap(find.text('复制地址'));
    await tester.pump();
    expect(copied, 'https://example.com/docs');
    expect(launcher.opened, isEmpty);
    expect(find.text('打开来源').hitTestable(), findsOneWidget);
    await tester.tap(find.text('打开来源'));
    await tester.pumpAndSettle();
    expect(launcher.opened, ['https://example.com/docs']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('diff reports changed lines and handles empty before content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ResponseInteractiveBlock(
          data: {
            'type': 'diff',
            'items': [
              {
                'label': '修改',
                'before': 'same\nold\nend',
                'after': 'same\nnew\nextra\nend',
              },
            ],
          },
        ),
      ),
    );
    expect(find.text('新增 2 行'), findsOneWidget);
    expect(find.text('移除 1 行'), findsOneWidget);
    expect(find.text('− old'), findsNothing);
    await _tap(tester, find.text('展开对比'));
    expect(find.text('− old'), findsOneWidget);
    expect(find.text('+ new'), findsOneWidget);
    await tester.pumpWidget(
      _host(
        const ResponseInteractiveBlock(
          data: {
            'type': 'diff',
            'items': [
              {'label': '新增', 'before': '', 'after': 'new'},
            ],
          },
        ),
      ),
    );
    expect(find.text('新增 1 行'), findsOneWidget);
    expect(find.text('移除 0 行'), findsOneWidget);
    expect(find.text('+ new'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
