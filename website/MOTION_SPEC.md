# Orialis — 从星系到身边

Source: user / 2026-10-02, Halo 02 reference, confirmed Q1–Q8, magnetic-card follow-up.
Prototype question: which spatial composition best makes immense AI capability feel like calm everyday companionship?

## Approved experience

Native scrolling drives a continuous approach to the original layered Halo, a passage along its ribbons, two product constellations, and a warm, quiet everyday ending. Schedule and news demos remain local and clearly labeled. No real accounts, saves, invented news, download promises or publishing.

## Render and visual language

- Halo: original native WebGL2 volumetric shader, custom camera, layered pearl membranes and twisting double ribbons. No remote assets.
- Product objects: DOM with real perspective, softly extruded edges, inset rims and broad contact shadows. Semantic buttons and readable content remain DOM.
- Palette: deep orbit #050913, pearl #eaf1ff, ice #acd7f7, lilac #aaa1ee, sunlight #edc7a4, quiet warm white #f3f2ee. Lumina light/material direction remains top-left; accent colors stay scarce.
- Type: Avenir Next / Helvetica Neue wordmark with tight optical tracking; PingFang SC / system Chinese. Large Orialis type is the opening visual, not an all-caps label.
- Composition: big negative spaces, asymmetric product stages, no repeated grid of marketing cards. Cards appear only as actual product objects.

## Three prototype compositions

- A / 循光旅程: immersive fixed cinematic stage, giant center wordmark, native scroll reveals sequential product constellations, final centered still life.
- B / 星系漫游: a navigable constellation map is the hero; products can be entered directly via orbit destinations. Persistent chapter controls support nonlinear exploration.
- C / 日常来信: an editorial, in-flow page with a split hero, generous reading space, and product objects drifting into their adjacent reading panels.

## Choreography

| Phase | Driver | Main event | Content |
| --- | --- | --- | --- |
| Arrival | short entrance, then scroll | far-to-near Halo; title remains readable | Orialis / 自然，围绕着你 |
| Ribbon | scroll | camera changes azimuth and approaches the ribbon | 沿着光，找到你的节奏 |
| Schedule | scroll, then click | three cards fly on separate arcs and magnetically settle | 给时间，一点秩序 |
| News | scroll, then click | information layers gather into a readable card | 让值得的，被看见 |
| Everyday | scroll then stillness | light changes to warm white; orbit becomes a companion | 光在身边，日子从容 |

Cards use time-based damped springs (stiffness ~180, damping ~22), bounded deltas/substeps, and continuous retargeting so reverse scrolling works. Camera uses exponential smoothing, not spring wobble. Pointer influence is restrained and removed after docking. No autoplay sound, scroll hijacking or unskippable intro.

## Accessibility and verification

Native scroll, anchor navigation, visible focus, keyboard-operable prototypes and modal demos; no reliance on dragging. Reduced motion removes camera travel and card flight and provides a normal document. Pausing ambient movement leaves navigation available. Stop rendering in hidden tabs. WebGL failure preserves a CSS silhouette and all content. Verify build, actual scroll/nav/demo paths, narrow layout, reduced motion, reverse travel and final calm. Prototype versions are explicitly labeled and switcher is development-only.
