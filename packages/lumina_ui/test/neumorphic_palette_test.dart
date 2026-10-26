import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_ui/lumina_ui.dart';

double _contrast(Color foreground, Color background) {
  final values = [foreground.computeLuminance(), background.computeLuminance()]
    ..sort();
  return (values[1] + .05) / (values[0] + .05);
}

void main() {
  test('neumorphic palette surfaces differ and keep text readable', () {
    for (final dark in [false, true]) {
      final colors = LuminaCardPalette.values
          .map(
            (palette) =>
                LuminaColors(dark: dark, tint: palette.tint, neumorphic: true),
          )
          .toList();

      expect(colors.map((color) => color.surface).toSet(), hasLength(6));
      for (final color in colors) {
        expect(_contrast(color.ink, color.surface), greaterThanOrEqualTo(4.5));
        expect(
          _contrast(color.muted, color.surface),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });
}
