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

### Layout fixes (`js/diagram.js`, `css/styles.css`)

1. **VPC CIDR labels** collided with the VPC title in the narrow spoke boxes and
   rendered as `Spoke 1 (App)12/16`. Now right-aligned to each box's edge.

2. **Node text overflowed its card.** Three separate causes: the badge was a
   fixed 80px block pinned right while the title started at a fixed offset,
   leaving `w − 152` px for the title (**0 px** on the 152px spoke cards);
   subtitles sat at y=42 inside cards only 42px tall, so the second line landed
   on the bottom border; and long subtitles simply ran past the right edge.
   `createNodeHtml` now **shrinks text to fit rather than truncating** — a
   slightly smaller label beats an ellipsis — sizes the badge to its own text,
   moves the badge to a bottom row when it would squeeze the title, and adapts
   the vertical rhythm to the card height. Clipping is the last resort and keeps
   the full string in a `<title>` tooltip.

3. **`<br/>` in subtitles was silently dropped** — SVG `<text>` does not honour
   it, so second lines (e.g. a node's IP under its FQDN) never rendered. The
   subtitle is now split on `<br/>` and each line emitted as its own positioned
   `<text>` element.

4. **Spoke VPC boxes widened** 180 → 200 px (nodes 152 → 172) using verified
   slack before the Region B block, so the domain-controller and app cards read
   at full size instead of being shrunk to fit.

5. **Overlay panels covered the canvas** (`css/styles.css`). The 360px left panel
   and 420px right drawer float above a full-bleed diagram, and the drawer also
   sat on top of the LEVEL bar. The canvas is now inset by whichever panel is
   open, and the LEVEL bar plus zoom cluster slide clear of the drawer.

### Content corrections (architecture audit)

Checked against the Terraform in this repo and against live measurements:

| Claim | Reality | Action |
|---|---|---|
| Region B TGW `ASN 64513` | nothing overrides `amazon_side_asn`; **both** regions use the module default `64512` | corrected to 64512 |
| "internet split-tunneled" | default is `gp_split_tunnel_routes = ["0.0.0.0/0"]` — a **full tunnel**; measured egress for client internet traffic is the firewall EIP | corrected to full tunnel |
| "Sub-30s Failover" | GA health check is 10s interval × 3 threshold = **30s detection floor**; sub-30s is not reachable | corrected to ~30s, with the arithmetic shown |

Verified accurate and left alone: PAN-OS 11.1.15, `m5.xlarge`/`m5.4xlarge`,
the ENI map (`ethernet1/1` HA2 at `device_index=1`, `1/2` trust, `1/3` untrust),
`loopback.1` carrying the floating EIP, Panorama at `10.11.0.10`, the per-region
GP pools (`10.10.200.0/24` / `10.20.200.0/24`), and preemption disabled.

### Sensitive-data audit

Scanned for public IPs, Elastic IPs, anycast addresses, instance/ENI/VPC/TGW
IDs, the AWS account ID, PAN-OS serials, auth codes and credentials: **none
present**. Every address in the data model is RFC1918 from the documented CIDR
plan. The only identifying strings are the author's name and the public
repository URL, both intentional.

Re-applying these after an upstream refresh means re-doing the edits above.
