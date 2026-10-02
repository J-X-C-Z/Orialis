# Orialis branding

Source: user / 2026-10-02, `ChatGPT 图像 2026年10月2日 23_53_12.png`.
The original reference is preserved as `source-reference.png`.

- `orialis-schedule.png`: blue planet/calendar artwork for Orialis.
- `orialis-news.png`: purple/gold planet/news artwork for Orialis News.

The artwork was extracted with imagegen background-extraction, removing the
poster text and outer backdrop. Both masters are 1024×1024 PNGs with transparent
surrounds. Only the two masters are declared as Flutter assets; the reference
poster and this file are not bundled.

`bash tool/update_brand_icons.sh` derives the five Android density sizes and
seven macOS sizes with macOS `sips`. Gradle selects `ic_launcher_news` only for
`newsApp=true`; standard and acceptance packages use `ic_launcher`. The macOS
product keeps the blue Orialis identity, with the warm News mark in its existing
News section.

Build Android variants sequentially, preserving each APK before building the
next. After `integration_test` is used, run the normal release build preparation
(without `--no-pub`) so Flutter regenerates its release plugin registrant.
An isolated build directory also avoids interference with concurrent work.
