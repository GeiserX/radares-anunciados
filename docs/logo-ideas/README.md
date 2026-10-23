# Logo ideas

Fourteen app-icon concepts for Radares Anunciados, to choose from. Nothing here replaces the current app icon
(`App/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`) or the README banner (`docs/images/banner.svg`).
Pick one and it gets its own change.

![All fourteen concepts under the iOS corner mask](contact-sheet.png)

## The brief

- The theme: Spanish roads, a radar announced ahead, the driver warned in time.
- The legal line shows in the drawing too. No icon draws a detector, an antenna or a received signal. Where waves
  appear, they are the spoken warning or the announcement going out, never a signal picked up from a radar.
- No official traffic sign is reproduced as it is, and no trademark is used.
- Every concept is a hand-written SVG on a 1024 × 1024 canvas, full bleed, with the important shapes kept clear
  of the iOS corner mask. Each one was checked at 120 px, which covers the 60 px home-screen size at 2×.
- No text in any font. The only letters (concept 04) are rectangles and one polygon drawn here, so the repo ships
  no font outlines and no font licence applies.

## Refined

| | Concept | Why |
|---|---|---|
| ![Navy road running to a horizon, amber arcs rising from the far point](png/01-horizonte-120.png) | **01 Horizonte** · [svg](01-horizonte.svg) | The road runs to the horizon and the warning rises from the point ahead. It says "something is coming, and you know it before you get there". |
| ![Black map pin with a white camera lens, on amber](png/02-pin-objetivo-120.png) | **02 Pin objetivo** · [svg](02-pin-objetivo.svg) | A map pin with a lens inside: a radar at a published place. The plainest way to say "positions, not detection". |
| ![Three white bars shrinking towards an amber lens, on blue](png/03-cuenta-atras-120.png) | **03 Cuenta atrás** · [svg](03-cuenta-atras.svg) | Three bars shrink towards the lens, like the distance counting down before the radar. Reads at any size. |

## Brutalist

| | Concept | Why |
|---|---|---|
| ![Black block letters RA on concrete grey, amber stripe under them](png/04-bloque-ra-120.png) | **04 Bloque RA** · [svg](04-bloque-ra.svg) | The initials built from raw blocks on concrete grey, with one amber stripe for the warning. Heavy, flat, no decoration. |
| ![Grid of grey slabs with one amber slab holding a black lens](png/05-rejilla-120.png) | **05 Rejilla** · [svg](05-rejilla.svg) | A grid of concrete slabs, one turned amber with a lens on it, and a road cut through the slabs below it. The map is a grid and one cell matters. |
| ![Black slab with a cut-out lens over a black chevron, on yellow](png/06-losa-flecha-120.png) | **06 Losa y flecha** · [svg](06-losa-flecha.svg) | A black slab that stands for the camera over a massive chevron pointing up the road. Hard edges, two colours. |

## Avant-garde

| | Concept | Why |
|---|---|---|
| ![Red wedge driving into a pale circle with a dark lens, on black](png/07-cuna-roja-120.png) | **07 Cuña roja** · [svg](07-cuna-roja.svg) | Constructivist: a red wedge drives into a pale circle with a dark lens. The wedge is the warning reaching you ahead of the radar. |
| ![White horizon line with a red dot and three thin rings, on black](png/08-suizo-120.png) | **08 Suizo** · [svg](08-suizo.svg) | Swiss grid: one horizon line, one red point on it, three thin rings going out. Asymmetric and quiet. |
| ![Blue block, yellow triangle and red circle with a lens, on cream](png/09-bauhaus-120.png) | **09 Bauhaus** · [svg](09-bauhaus.svg) | Three primary shapes: a blue block with a lane cut in it, a yellow triangle for caution, a red circle with a lens. |
| ![Amber voice waveform with a white lens at its centre, on black](png/10-ondas-120.png) | **10 Ondas de voz** · [svg](10-ondas.svg) | The app's warning is spoken, so the mark is a voice waveform with a lens at its centre. |

## Crazy

| | Concept | Why |
|---|---|---|
| ![Purple owl with two camera-lens eyes, on hot pink](png/11-buho-120.png) | **11 Búho** · [svg](11-buho.svg) | An owl with two camera lenses for eyes on hot pink. It watches the road so you do not have to. |
| ![Yellow snail with an orange lens shell on a dark road](png/12-caracol-120.png) | **12 Caracol** · [svg](12-caracol.svg) | A snail whose shell is a lens, crawling along the lane line. Radar ahead: snail speed. |
| ![Black megaphone with white sound arcs, on teal](png/13-megafono-120.png) | **13 Megáfono** · [svg](13-megafono.svg) | A megaphone shouting the warning out loud, because the app announces the radar with a voice. |
| ![Fried egg with a lens for a yolk on dark asphalt](png/14-huevo-frito-120.png) | **14 Huevo frito** · [svg](14-huevo-frito.svg) | A fried egg on the asphalt whose yolk is a lens. Miss the warning and you are "frito". |

## Rendering

`render.sh` turns every SVG into `png/<name>-1024.png` and `png/<name>-120.png` and builds `contact-sheet.png`
(two rows of seven, each icon under the iOS corner mask, on a dark background). It needs `rsvg-convert`
(librsvg) and ImageMagick 7: `brew install librsvg imagemagick`. The sheet takes exactly fourteen icons; adding a
concept means adding it to the last row in the script.
