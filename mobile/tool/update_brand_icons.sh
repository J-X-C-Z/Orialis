#!/usr/bin/env bash
set -euo pipefail

# Native-size derivatives of approved PNG masters; does not redesign the logo.
mobile_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
schedule_icon="$mobile_root/assets/branding/orialis-schedule.png"
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
