import 'dart:convert';

/// Matches band/vela/src/common/protocol.js, not a verified Xiaomi limit.
class WearProtocol {
  static const namespace = 'orialis.wear.v1';
  // Conservative Fangcun transport budget, including the JSON envelope.
  static const maxFrameBytes = 2200,
      maxSnapshotBytes = 16384,
      maxChunkBytes = 4096;
  static String encode(String type, Map<String, Object?> payload) {
    final data = jsonEncode({
      'ns': namespace,
      'type': type,
      'payload': payload,
    });
    if (utf8.encode(data).length > maxFrameBytes) {
      throw const FormatException('frame exceeds byte limit');
    }
    return data;
  }

  static Map<String, dynamic> decode(String data) {
    if (utf8.encode(data).length > maxFrameBytes) {
      throw const FormatException('frame exceeds byte limit');
    }
    final frame = jsonDecode(data);
    if (frame is! Map<String, dynamic> ||
        frame['ns'] != namespace ||
        frame['type'] is! String ||
        frame['payload'] is! Map) {
      throw const FormatException('invalid envelope');
    }
    return frame;
  }

  static String checksum(String text) {
    var a = 1, b = 0;
    for (final byte in utf8.encode(text)) {
      a = (a + byte) % 65521;
      b = (b + a) % 65521;
    }
    return ((b << 16) | a).toRadixString(16).padLeft(8, '0');
  }

  static List<String> splitSnapshot(Map<String, Object?> snapshot) {
    final transferId = snapshot['transferId'], revision = snapshot['revision'];
    if (transferId is! String ||
        transferId.isEmpty ||
        transferId.length > 96 ||
        revision is! int ||
        revision < 0) {
      throw const FormatException('invalid transfer identity');
    }
    final text = jsonEncode(snapshot);
    if (utf8.encode(text).length > maxSnapshotBytes) {
      throw const FormatException('snapshot exceeds byte limit');
    }
    final chunks = <String>[];
    var chunk = '';
    final digest = checksum(text);
    bool fits(String value) =>
        utf8
            .encode(
              jsonEncode({
                'ns': namespace,
                'type': 'snapshot.part',
                'payload': {
                  'transferId': transferId,
                  'revision': revision,
                  'index': 31,
                  'count': 32,
                  'checksum': digest,
                  'chunk': value,
                },
              }),
            )
            .length <=
        maxFrameBytes;
    for (final rune in text.runes) {
      final scalar = String.fromCharCode(rune);
      if (!fits(chunk + scalar)) {
        if (chunk.isEmpty) {
          throw const FormatException('frame metadata too large');
        }
        chunks.add(chunk);
        chunk = '';
      }
      chunk += scalar;
    }
    chunks.add(chunk);
    if (chunks.length > 32) throw const FormatException('too many parts');
    return List.generate(
      chunks.length,
      (index) => encode('snapshot.part', {
        'transferId': transferId,
        'revision': revision,
        'index': index,
        'count': chunks.length,
        'checksum': digest,
        'chunk': chunks[index],
      }),
    );
  }
}
