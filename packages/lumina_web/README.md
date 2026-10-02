# Lumina Web · phase 1

A React + TypeScript implementation of Lumina's foundational controls. Run `npm install && npm run dev` here for the interactive showcase; `npm run build` emits the showcase in `dist/` and an ESM library in `lib-dist/`.

The versioned cross-platform source of colors, spacing, radii, sizes and timing is [`../lumina_tokens/lumina.v1.json`](../lumina_tokens/lumina.v1.json). The light palette and numeric metrics mirror the Flutter package's `design_tokens.dart`; the dark palette adds a tuned low-glare glass variant. React imports the JSON directly. Flutter consumes a generated Dart const file; after changing the JSON, run `python3 ../lumina_tokens/generate_flutter.py`, then `python3 ../lumina_tokens/generate_flutter.py --check` to verify it is current.

`LuminaProvider` owns a persistent `system | light | dark` preference. The system setting tracks `prefers-color-scheme` changes. Components use native HTML inputs/buttons/dialogs with visible focus, labels, reduced-motion and reduced-transparency support. The controls are Button, IconButton, TextField, Checkbox, Switch, Slider, Segmented, Card, TopBar, Menu, Dialog and Toast. The Three.js experiment loads only when its toggle is enabled in the showcase; it is not part of the interaction layer.

```tsx
import { LuminaProvider, LuminaButton } from '@orialis/lumina-web';
import '@orialis/lumina-web/style.css';

<LuminaProvider><LuminaButton variant="primary">继续</LuminaButton></LuminaProvider>
```

Next phases can cover the remaining Material 3 categories after parity is established against the fixed Flutter SDK inventory. This package is a component library and showcase, not an Orialis web client.

## Glass and water interaction

Web glass follows the Flutter material's top-left light, four-stop body gradient, refracted rim, recessed tracks and pressed shadow. `LuminaProvider` applies the shared JSON palette as CSS variables in both themes. Rendering is a CSS approximation of Flutter's painter, not a pixel-identical renderer.

Buttons (except quiet), segmented options, checkbox/switch surfaces and sliders enable water by default. Use `<LuminaButton water={false}>` to disable it. Cards and top bars opt in with `water`; this also works for the showcase's “触感如水” panel.

Inspired by the interaction at https://demo.jxcz.top/: mouse movement leaves a fading wake; pointer-down creates a wave. Touch movement and keyboard navigation do not generate wakes. The implementation is original Canvas2D wave-field shading, without adding Three.js to the controls or moving their text. A provider shares one animation scheduler, at most four active fields (two in the lower-cost mode), bounded resolution and 1.4-second idle cleanup. Hidden/offscreen surfaces stop; reduced motion, reduced transparency and forced colors skip the wave field. Existing static pressed/focus states remain. Hardware concurrency and repeated slow frames select lower-cost rendering. Three.js remains an optional showcase-only dependency.
