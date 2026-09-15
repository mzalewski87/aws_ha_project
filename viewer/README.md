# Interactive Architecture Viewer

Zero-dependency browser app: an interactive walkthrough and resilience
simulator for the multi-region Active/Passive VM-Series architecture this repo
deploys.

**Live:** published to GitHub Pages from this folder on every push to `main`
(see `.github/workflows/pages.yml`). Open it full-tab — it is a canvas app and
wants the width.

**Local:** open `index.html` directly. No web server, no build step, no network
access required (`file://` works).

## Contents

| Path | What |
|------|------|
| `index.html` | the app (English) |
| `css/styles.css` | all styling |
| `js/diagram.js` | SVG diagram: nodes, VPC boxes, links, camera |
| `js/data_en.js` | English architecture data (`ARCHITECTURE_DATA_EN`) |
| `js/data.js` | Polish data set, retained as the fallback the app expects |
| `js/app.js` | app shell, UI strings, selection/search |
| `js/animations.js`, `js/scenarios.js`, `js/icons.js` | flows, failure walkthroughs, icons |

## English-only

Upstream ships bilingual (`index.html` PL + `index_en.html` EN). Only English is
published here: `index_en.html` became `index.html` and the `PL | EN` switcher
was removed. `js/data.js` is kept because `app.js` treats the Polish set as its
fallback — dropping it risks a blank diagram if the language ever resolves to
anything but `en`.

## Local changes vs upstream

Three layout fixes, all in this copy only:

1. **VPC CIDR labels** (`js/diagram.js`) — were positioned at fixed `x` offsets
   and collided with the VPC title inside the 180px-wide spoke boxes, rendering
   as `Spoke 1 (App)12/16`. Now right-aligned (`text-anchor="end"`) to each
   box's right edge.

2. **Node title vs badge** (`js/diagram.js`, `createNodeHtml`) — the badge was a
   fixed 80px block pinned to the card's right edge while the title started at a
   fixed offset, leaving `w − 152` px for the title: exactly **0 px** on the
   152px spoke nodes, so titles ran under the badge and outside the card. The
   badge is now sized to its own text; when a title still will not fit, tall
   cards move the badge to a bottom row (freeing the full width) and anything
   left over is ellipsized with the full string kept in a `<title>` tooltip.

3. **Overlay panels covering the canvas** (`css/styles.css`) — the 360px left
   panel and 420px right drawer float above a full-bleed diagram, and the drawer
   also sat on top of the LEVEL bar. The canvas is now inset by whichever panel
   is open (`:has()`), and the LEVEL bar plus zoom cluster slide clear of the
   drawer. The SVG keeps its fixed `viewBox`, so narrowing the box rescales the
   drawing into the visible area instead of hiding its edges.

Re-applying these after an upstream refresh means re-doing the three edits
above; they are small and localised.
