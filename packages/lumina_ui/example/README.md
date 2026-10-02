# Lumina Flutter showcase

Run `flutter run -d chrome`, or build with `flutter build web --release`.
Use `?catalog=1` to begin with the complete 28-category collection; append
`&dark=1&liquid=1&locale=zh` for Chinese dark liquid glass. Preferences remain
editable within the page. Examples keep their state in memory only.

## Local Chinese font

`assets/fonts/LuminaShowcaseSans-Regular.ttf` is a locally bundled regular-weight
subset derived from [Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc),
so the demo's English and common Chinese text does not need a remote font fallback.
It retains Latin, CJK punctuation, kana, CJK Extension A, the basic CJK block and
fullwidth characters. Other writing systems may still use Flutter fallback.
The font belongs to this showcase, not the library or host application.

Source variable font SHA256:
`a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`.
It was instantiated at weight 400 and subset with fontTools 4.x; the derivative's
family/PostScript names were changed to Lumina Showcase Sans. Font copyright and
SIL OFL 1.1 are retained in the adjacent `assets/fonts/OFL.txt`, included in assets.
The font's license does not select a license for the Lumina component library.
