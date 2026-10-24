import 'package:xml/xml.dart';

/// The static drawing subset accepted from generated replies.
class ResponseSvg {
  static bool isValid(Object? source) {
    if (source is! String ||
        source.isEmpty ||
        source.runes.length > 16000 ||
        source.contains('<!') ||
        source.contains('<?')) {
      return false;
    }
    try {
      final document = XmlDocument.parse(source);
      final root = document.rootElement;
      if (root.name.qualified != 'svg' ||
          root.getAttribute('xmlns') != 'http://www.w3.org/2000/svg') {
        return false;
      }
      final box = root.getAttribute('viewBox')?.trim().split(RegExp(r'[\s,]+'));
      if (box == null || box.length != 4) return false;
      final values = box.map(double.tryParse).toList();
      if (values.any((v) => v == null || !v.isFinite) ||
          values[2]! <= 0 ||
          values[3]! <= 0 ||
          values[2]! > 10000 ||
          values[3]! > 10000) {
        return false;
      }
      var count = 0;
      for (final node in document.descendants) {
        if (node is! XmlElement) continue;
        if (++count > 256 || !_elements.contains(node.name.qualified)) {
          return false;
        }
        for (final attribute in node.attributes) {
          final name = attribute.name.qualified;
          final value = attribute.value;
          if (!_attributes.contains(name)) return false;
          if (name == 'xmlns' && value != 'http://www.w3.org/2000/svg') {
            return false;
          }
          if (value.contains(RegExp(r'[\\<>]'))) return false;
          if (RegExp(r'url\s*\(', caseSensitive: false).hasMatch(value) &&
              !(const {'fill', 'stroke', 'clip-path'}.contains(name) &&
                  RegExp(r'^url\(#[a-zA-Z_][\w.-]*\)$').hasMatch(value))) {
            return false;
          }
        }
      }
      return true;
    } on XmlException {
      return false;
    }
  }

  static const _elements = {
    'svg',
    'g',
    'defs',
    'path',
    'rect',
    'circle',
    'ellipse',
    'line',
    'polyline',
    'polygon',
    'linearGradient',
    'radialGradient',
    'stop',
    'clipPath',
    'title',
    'desc',
  };
  static const _attributes = {
    'xmlns',
    'viewBox',
    'width',
    'height',
    'id',
    'x',
    'y',
    'x1',
    'y1',
    'x2',
    'y2',
    'cx',
    'cy',
    'r',
    'rx',
    'ry',
    'd',
    'points',
    'fill',
    'fill-opacity',
    'fill-rule',
    'stroke',
    'stroke-width',
    'stroke-opacity',
    'stroke-linecap',
    'stroke-linejoin',
    'stroke-miterlimit',
    'stroke-dasharray',
    'stroke-dashoffset',
    'opacity',
    'transform',
    'clip-path',
    'clip-rule',
    'clipPathUnits',
    'gradientUnits',
    'gradientTransform',
    'offset',
    'stop-color',
    'stop-opacity',
    'fx',
    'fy',
    'spreadMethod',
    'preserveAspectRatio',
  };
}
