import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/chat/domain/response_ui.dart';
import 'package:orialis_mobile/features/chat/presentation/safe_markdown.dart';

String fixture(String name) =>
    File('../docs/contracts/response-ui-v1$name.example.json')
        .readAsStringSync();

Map<String, dynamic> document(List<Map<String, dynamic>> blocks) => {
  'version': 1,
  'fallback': '作者提供的数据；展示不会自动执行动作。',
  'blocks': blocks,
};

Map<String, dynamic> block(String type, List<Map<String, dynamic>> items) => {
  'type': type,
  'items': items,
};

Map<String, dynamic> plot(String kind, List<Map<String, dynamic>> series) => {
  ...block('plot', series),
  'kind': kind,
};

Map<String, dynamic> series(String label, List<num> axes, {num y = 20}) => {
  'label': label,
  'points': [
    for (final x in axes) {'x': x, 'y': y},
  ],
};

ResponseUiDocument? parseBlock(Map<String, dynamic> value) =>
    ResponseUiDocument.parse(jsonEncode(document([value])));

void main() {
  test('Board fixture adds three types and three plot kinds to v1', () {
    final source = fixture('.board');
    final parsed = ResponseUiDocument.parse(source)!;
    expect(parsed.supported, isTrue);
    expect(parsed.version, 1);
    expect(parsed.blocks.map((b) => b.type), [
      'progress',
      'heatmap',
      'accordion',
      'plot',
      'plot',
      'plot',
    ]);
    expect(parsed.blocks.skip(3).map((b) => b.data['kind']), [
      'area',
      'bar',
      'radar',
    ]);
    final authored = jsonDecode(source) as Map<String, dynamic>;
    for (var i = 0; i < parsed.blocks.length; i++) {
      expect(parsed.blocks[i].data, authored['blocks'][i]);
    }
    expect(parsed.fallback, contains('演示数据'));
    expect(utf8.encode(source).length, lessThanOrEqualTo(32768));
  });

  test('both existing fixtures retain all seventeen legacy types', () {
    final original = ResponseUiDocument.parse(fixture(''))!;
    final extended = ResponseUiDocument.parse(fixture('.extended'))!;
    expect(original.supported && extended.supported, isTrue);
    expect(original.blocks.map((b) => b.type).toSet(), {
      'metrics',
      'chart',
      'tabs',
      'checklist',
      'choices',
      'svg',
    });
    expect(extended.blocks.map((b) => b.type).toSet(), {
      'diagram',
      'math',
      'plot',
      'timeline',
      'simulation',
      'form',
      'table',
      'sources',
      'diff',
      'media',
      'actions',
    });
  });

  test('multiple complete fences preserve surrounding text and every fallback', () {
    final sources = [fixture(''), fixture('.extended'), fixture('.board')];
    final source =
        '前言\n\n${sources.map((s) => '```orialis-ui\n$s\n```').join('\n\n')}\n\n结语';
    final expected =
        '前言\n\n${sources.map((s) => ResponseUiDocument.parse(s)!.fallback).join('\n\n')}\n\n结语';
    expect(responseUiPlainText(source), expected);
  });

  test(
    'future version uses fallback; unknown v1 types and kinds stay code',
    () {
      final future = {
        ...document([
          {'type': 'future'},
        ]),
        'version': 99,
      };
      final parsed = ResponseUiDocument.parse(jsonEncode(future))!;
      expect(parsed.supported, isFalse);
      expect(parsed.blocks, isEmpty);
      expect(parsed.fallback, future['fallback']);
      expect(
        parseBlock(
          block('html', [
            {'label': '未知', 'content': 'x'},
          ]),
        ),
        isNull,
      );
      expect(
        parseBlock(
          plot('surface', [
            series('未知', [1, 2, 3]),
          ]),
        ),
        isNull,
      );
      final malformed = jsonEncode(
        document([
          block('progress', [
            {'label': '越界', 'value': 101},
          ]),
        ]),
      );
      final fenced = '```orialis-ui\n$malformed\n```';
      expect(responseUiPlainText(fenced), fenced);
    },
  );

  test(
    'progress accepts defaults, both styles, zero, and finite positive max',
    () {
      for (final style in [null, 'linear', 'ring']) {
        expect(
          parseBlock({
            ...block('progress', [
              {'label': '零', 'value': 0},
              {'label': '默认满分', 'value': 100, 'detail': '字' * 240},
              {'label': '自定义量表', 'value': 3, 'max': 5},
              {'label': '大数值量表', 'value': 1e6, 'max': 1e6},
              {'label': '小数值量表', 'value': 0.1, 'max': 0.2},
            ]),
            if (style != null) 'style': style,
          }),
          isNotNull,
          reason: '$style',
        );
      }
      for (final item in <Map<String, dynamic>>[
        {'label': '缺值'},
        {'label': '字符串', 'value': '50'},
        {'label': '布尔值', 'value': true},
        {'label': '负值', 'value': -1},
        {'label': '越界', 'value': 101},
        {'label': '自定义越界', 'value': 6, 'max': 5},
        {'label': '零上限', 'value': 0, 'max': 0},
        {'label': '负上限', 'value': 0, 'max': -5},
        {'label': '字符串上限', 'value': 0, 'max': '100'},
        {'label': '过大上限', 'value': 0, 'max': 1000001},
        {'label': '过长说明', 'value': 20, 'detail': '字' * 241},
      ]) {
        expect(parseBlock(block('progress', [item])), isNull, reason: '$item');
      }
      expect(
        parseBlock({
          ...block('progress', [
            {'label': '样式', 'value': 20},
          ]),
          'style': 'spinner',
        }),
        isNull,
      );
    },
  );

  test('heatmap uses bounded values and exact calendar dates', () {
    expect(
      parseBlock(
        block('heatmap', [
          {'label': '闰日', 'value': 0, 'date': '2032-02-29'},
          {'label': '最大值', 'value': 1e6, 'date': '2032-03-01'},
        ]),
      ),
      isNotNull,
    );
    for (final date in [
      null,
      '2030-02-29',
      '2030-04-31',
      '2030-13-01',
      '2030-00-01',
      '0000-01-01',
      '2030-1-01',
      '2030-01-1',
      '20300101',
      '2030-01-01T00:00:00Z',
      '2030-01-01 ',
    ]) {
      expect(
        parseBlock(
          block('heatmap', [
            {'label': '日期', 'value': 1, 'date': date},
          ]),
        ),
        isNull,
        reason: '$date',
      );
    }
    for (final value in [-1, 1000001, '12', true, null]) {
      expect(
        parseBlock(
          block('heatmap', [
            {'label': '数值', 'value': value, 'date': '2030-01-01'},
          ]),
        ),
        isNull,
        reason: '$value',
      );
    }
    expect(
      parseBlock(
        block('heatmap', [
          {'label': '甲', 'value': 1, 'date': '2030-01-01'},
          {'label': '乙', 'value': 2, 'date': '2030-01-01'},
        ]),
      ),
      isNull,
    );
  });

  test('accordion content retains the existing 4000-character bound', () {
    expect(
      parseBlock(
        block('accordion', [
          {'label': '说明', 'content': '字' * 4000},
        ]),
      ),
      isNotNull,
    );
    for (final content in ['', '   ', '字' * 4001, 42, null]) {
      expect(
        parseBlock(
          block('accordion', [
            {'label': '说明', 'content': content},
          ]),
        ),
        isNull,
      );
    }
  });

  test(
    'new plot kinds retain numeric limits and radar requires aligned axes',
    () {
      for (final kind in ['area', 'bar', 'radar']) {
        expect(
          parseBlock(
            plot(kind, [
              series('第一轮', [1, 2, 3], y: 0),
              series('第二轮', [1, 2, 3], y: 1e6),
            ]),
          ),
          isNotNull,
        );
        expect(
          parseBlock(
            plot(kind, [
              series('超界', [1, 2, 3], y: 1000001),
            ]),
          ),
          isNull,
        );
      }
      for (final kind in ['area', 'bar']) {
        expect(
          parseBlock(
            plot(kind, [
              series('负值', [1, 2, 3], y: -20),
            ]),
          ),
          isNotNull,
        );
      }
      // Radar adds a minimum of three; the shared maximum remains 120 points.
      expect(
        parseBlock(
          plot('radar', [series('多轴', List<num>.generate(13, (i) => i))]),
        ),
        isNotNull,
      );
      for (final invalid in [
        plot('radar', [
          series('不足三点', [1, 2]),
        ]),
        plot('radar', [
          series('负值', [1, 2, 3], y: -1),
        ]),
        plot('radar', [
          series('甲', [1, 2, 3]),
          series('乙', [1, 2, 4]),
        ]),
        plot('radar', [
          series('甲', [1, 2, 3]),
          series('乙', [3, 2, 1]),
        ]),
        plot('radar', [
          series('甲', [1, 2, 3]),
          series('乙', [1, 2, 3, 4]),
        ]),
        plot('radar', [series('太多', List<num>.generate(121, (i) => i))]),
        plot('radar', [
          series('重复轴', [1, 1, 2]),
        ]),
        plot('radar', [
          {
            'label': '甲',
            'points': [
              {'x': 1, 'y': 10, 'label': '概念'},
              {'x': 2, 'y': 20},
              {'x': 3, 'y': 30},
            ],
          },
          {
            'label': '乙',
            'points': [
              {'x': 1, 'y': 10, 'label': '练习'},
              {'x': 2, 'y': 20},
              {'x': 3, 'y': 30},
            ],
          },
        ]),
      ]) {
        expect(parseBlock(invalid), isNull, reason: '$invalid');
      }
    },
  );

  test('non-finite JSON numbers never reach any new numeric renderer', () {
    for (final value in [
      block('progress', [
        {'label': '值', 'value': 12345},
      ]),
      block('progress', [
        {'label': '上限', 'value': 0, 'max': 12345},
      ]),
      block('heatmap', [
        {'label': '值', 'value': 12345, 'date': '2030-01-01'},
      ]),
      for (final kind in ['area', 'bar', 'radar'])
        plot(kind, [
          series('值', [1, 2, 3], y: 12345),
        ]),
    ]) {
      final source = jsonEncode(document([value])).replaceAll('12345', '1e999');
      expect(ResponseUiDocument.parse(source), isNull);
    }
  });

  test('new types keep 12 items, 12 blocks and the UTF-8 document limit', () {
    for (final entry in <String, Map<String, dynamic>>{
      'progress': {'label': '记录', 'value': 0},
      'heatmap': {'label': '记录', 'value': 0, 'date': '2030-01-01'},
      'accordion': {'label': '记录', 'content': '说明'},
    }.entries) {
      expect(parseBlock(block(entry.key, [])), isNull);
      expect(
        parseBlock(
          block(
            entry.key,
            List.generate(
              12,
              (i) => {
                ...entry.value,
                if (entry.key == 'heatmap')
                  'date': '2030-01-${(i + 1).toString().padLeft(2, '0')}',
              },
            ),
          ),
        ),
        isNotNull,
      );
      expect(
        parseBlock(block(entry.key, List.filled(13, entry.value))),
        isNull,
      );
    }
    final simple = block('progress', [
      {'label': '记录', 'value': 0},
    ]);
    expect(
      ResponseUiDocument.parse(jsonEncode(document(List.filled(12, simple)))),
      isNotNull,
    );
    expect(
      ResponseUiDocument.parse(jsonEncode(document(List.filled(13, simple)))),
      isNull,
    );
    final raw = jsonEncode(document([simple]));
    final exact = '$raw${' ' * (32768 - utf8.encode(raw).length)}';
    expect(utf8.encode(exact).length, 32768);
    expect(ResponseUiDocument.parse(exact), isNotNull);
    expect(ResponseUiDocument.parse('$exact '), isNull);
  });
}
