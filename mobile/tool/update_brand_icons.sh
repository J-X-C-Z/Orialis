#!/usr/bin/env bash
set -euo pipefail

# Native-size derivatives of approved PNG masters; does not redesign the logo.
mobile_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
schedule_icon="$mobile_root/assets/branding/orialis-neumorphic.png"
news_icon="$mobile_root/assets/branding/orialis-news.png"
for item in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density="${item%%:*}"
  pixels="${item##*:}"
  destination="$mobile_root/android/app/src/main/res/mipmap-$density"
  mkdir -p "$destination"
  sips -z "$pixels" "$pixels" "$schedule_icon" --out "$destination/ic_launcher.png" >/dev/null
  sips -z "$pixels" "$pixels" "$news_icon" --out "$destination/ic_launcher_news.png" >/dev/null
done
for pixels in 16 32 64 128 256 512 1024; do
  sips -z "$pixels" "$pixels" "$schedule_icon" --out "$mobile_root/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$pixels.png" >/dev/null
done
# ICO entries can contain the PNG derivatives directly (Windows Vista+).
python3 - "$mobile_root" <<'PY'
from pathlib import Path
import struct
import sys
root = Path(sys.argv[1])
images = [(size, (root / f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png').read_bytes()) for size in (16, 32, 64, 128, 256)]
offset = 6 + 16 * len(images)
entries, payload = [], []
for size, data in images:
    dimension = 0 if size == 256 else size
    entries.append(struct.pack('<BBBBHHII', dimension, dimension, 0, 0, 1, 32, len(data), offset))
    payload.append(data)
    offset += len(data)
(root / 'windows/runner/resources/app_icon.ico').write_bytes(struct.pack('<HHH', 0, 1, len(images)) + b''.join(entries) + b''.join(payload))
PY
