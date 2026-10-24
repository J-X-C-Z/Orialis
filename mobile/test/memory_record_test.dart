import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/memory/domain/memory_record.dart';

void main() {
  MemoryRecord record(Map<String, Object?> fields) => MemoryRecord.fromMap({
    'id': 'one',
    'createdAt': '2026-10-25T00:00:00Z',
    'title': '记忆',
    'urls': <String>[],
    ...fields,
  });

  test('classification and video result fields survive a local roundtrip', () {
    final initial = record({
      'category': 'ai',
      'sourceUrl': 'https://b23.tv/Real?share=1',
      'videoStatus': 'analyzed',
      'videoSummary': '字幕中的智能体知识',
      'analysisRequestId': 'memory-v2-one',
    });
    final stored = MemoryRecord.fromMap(initial.toMap());
    expect(stored.category, 'ai');
    expect(stored.videoStatus, 'analyzed');
    expect(stored.matches('智能体'), isTrue);
    expect(stored.primarySourceUrl, 'https://b23.tv/Real?share=1');
    expect(stored.hasVideoSource, isTrue);
    expect(stored.analysisRequestId, 'memory-v2-one');
  });

  test('original share evidence is retained when verified video URL is added', () {
    const signed =
        'https://www.xiaohongshu.com/explore/123?xsec_token=A%2BB==&xsec_source=app_share';
    final memory = record({
      'urls': [signed, 'https://b23.tv/Original'],
      'sourceUrl': 'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
    });
    expect(memory.urls, [signed, 'https://b23.tv/Original']);
    expect(
      memory.primarySourceUrl,
      'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
    );
  });

  test('old and malformed optional metadata remain readable without unsafe launch URLs', () {
    final memory = record({
      'category': 'made-up',
      'sourceUrl': 'javascript:bad()',
      'urls': ['https://example.com/article', 'https://b23.tv/Original'],
    });
    expect(memory.category, isNull);
    expect(memory.sourceUrl, isNull);
    expect(memory.primarySourceUrl, 'https://b23.tv/Original');
    expect(record({}).primarySourceUrl, isNull);
    expect(
      MemoryRecord.isVideoUrl(
        'https://bilibili.com.evil.test/video/BV1xx411c7mD',
      ),
      isFalse,
    );
    expect(
      MemoryRecord.isVideoUrl(
        'https://bilibili.com@evil.test/video/BV1xx411c7mD',
      ),
      isFalse,
    );
  });
}
