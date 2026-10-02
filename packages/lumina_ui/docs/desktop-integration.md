# Desktop integration

Import `package:lumina_ui/lumina_ui.dart` for the stable UI API. Wrap an
editor, dialog, or other bounded desktop interaction with
`LuminaKeyboardScope(onEnter: ..., onEscape: ..., child: ...)` to connect
Enter and Escape to the host's callbacks. A focused editable child retains its
own Enter submission behavior. Tab traversal uses Flutter's normal focus
traversal; Lumina controls provide visible focus feedback and Enter/Space
activation.

`LuminaKeyboardScope` owns no route, dialog, or business state. The host decides
whether Escape closes an overlay or cancels a form, and whether Enter saves or
advances. Keep shortcuts that navigate or create records outside text inputs in
the host shell so text entry is never intercepted.

The package keeps colors, typography, and material in the existing Lumina
theme. Use `ThemeMode.system`, `ThemeMode.light`, or `ThemeMode.dark` in the host
and provide the corresponding `LuminaTheme.brightness`. Respect Flutter's
`MediaQuery.textScaler`; the shared components size headings and header insets
from the active text scale. Keep narrow windows single-column and allow content
to wrap instead of imposing a minimum desktop width.

## Verification status

Ran the keyboard and component regression suites with a copy-on-write Flutter
SDK and package cache under the Paperclip run scratch directory. `XDG_CONFIG_HOME`
was directed into scratch so the run did not write the installed SDK or the
user's Flutter config.

```text
flutter test --no-pub test/lumina_keyboard_test.dart test/lumina_components_test.dart
25 tests passed
```

The keyboard tests cover Tab order and focused activation, Enter/Escape
callbacks, and separation of `TextInputAction.done` submission from a hardware
Enter event. Component regressions cover light/dark palette roles, dark content
at 2x text scale without overflow, reduced motion, high-performance blur
fallback, and interactive controls. Native macOS window screenshots and
product-host behavior were not exercised here.

## Clear desktop material

Set `LuminaThemeData(liquidGlass: true)` in the desktop host. This opts surfaces,
buttons and segmented selection wells/lenses into a grain-free translucent body,
broad specular wash, thin refractive rim and diffuse outside-only shadows. It
removes the sculpted material's solid lower extrusion and deep inset bevel.
High-performance mode retains these soft shadows; live backdrop filtering is
still restricted to explicitly opted-in chrome (such as the selected sidebar
item), not every list row. Opaque accessibility modes retain solid fills and
focus outlines. The default is false, preserving existing mobile material.
