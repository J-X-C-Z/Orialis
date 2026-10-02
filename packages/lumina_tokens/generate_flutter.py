"""Generate Flutter const tokens from the cross-platform Lumina JSON baseline."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / 'lumina.v1.json'
TARGET = ROOT.parent / 'lumina_ui/lib/src/lumina_tokens_generated.dart'

def render() -> str:
    data = json.loads(SOURCE.read_text())
    lines = [
        '// Generated from packages/lumina_tokens/lumina.v1.json. Do not edit.',
        "import 'package:flutter/widgets.dart';",
        '',
    ]
    for mode in ('light', 'dark'):
        lines.append(f'class LuminaToken{mode.title()} {{')
        for name, value in data['color'][mode].items():
            lines.append(f'  static const {name} = Color(0xFF{value[1:].upper()});')
        lines.extend(['}', ''])
    for group, key in [('Spacing', 'spacing'), ('Radius', 'radius'), ('Size', 'size'), ('Motion', 'motionMs'), ('Glass', 'glass')]:
        lines.append(f'class LuminaToken{group} {{')
        for name, value in data[key].items():
            scalar = f'{value}.0' if isinstance(value, int) and group not in ('Motion',) else str(value)
            lines.append(f'  static const {name} = {scalar};')
        lines.extend(['}', ''])
    return '\n'.join(lines)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = render()
    if args.check:
        if not TARGET.exists() or TARGET.read_text() != expected:
            raise SystemExit('Flutter Lumina tokens are out of date; run generate_flutter.py')
    else:
        TARGET.write_text(expected)
