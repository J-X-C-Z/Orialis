# Lumina tokens v1

`lumina.v1.json` is the cross-platform design-value source for Flutter Lumina and Lumina Web. Its light colors, spacing, radii, sizes and motion values mirror Flutter's `packages/lumina_ui/lib/src/design_tokens.dart` as of this version. Dark colors define accessible, low-glare glass surfaces for both clients. Change values here first and update the platform mappings together. Components may add platform-specific interaction details without changing the token meaning.

## Palette families and brand (1.1.0)

- `palette` holds the six `LuminaCardPalette` tints (mist, ocean, sage, amber, rose, lavender). Flutter derives each family's raised body, recess, glass accent and text from its tint in `LuminaColors`; the JSON stores only the tint. Priority mapping stays in code: rose important+urgent, amber urgent, ocean important, sage ordinary, mist unclassified; lavender carries no priority.
- `brand` holds the Halo colors per theme: `ice` and `lilac` for brand moments (the mark, the assistant working), `sun` for the moment a person confirms something, and `sunInk` as its readable text tone. Dark values are the Halo 02 originals; light values are tuned for the paper background. Use them sparingly; they are not general UI colors.

Flutter reads them as `LuminaTokenPalette` and `LuminaTokenBrandLight` / `LuminaTokenBrandDark`. Lumina Web exposes them as `--palette-<name>` and `--brand-<name>` CSS variables.
