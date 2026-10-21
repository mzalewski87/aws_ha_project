# Interactive Architecture Viewer

Zero-dependency browser app: an interactive walkthrough and resilience
simulator for the multi-region Active/Passive VM-Series architecture this repo
deploys — with both management paths (A = self-hosted Panorama,
B = Strata Cloud Manager) switchable on the diagram.

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

## Deep links

Everything after `#` is optional and combinable, e.g.
`index.html#path=a&mode=presentation&slide=7`:

| Key | Values |
|-----|--------|
| `path` | `a` (Panorama) / `b` (Strata Cloud Manager, default) — `?path=a` works too |
| `mode` | `overview`, `flows`, `scenarios`, `presentation` |
| `slide` | slide number (1-based, with `mode=presentation`) |
| `flow` / `scenario` + `step` | id from `js/data_en.js`, step 1-based |
| `view` | a LEVEL preset: `overview`, `ha-cluster`, `region-a`, `region-b`, `mgmt` |
| `node` (+ `zoom`) | focus a component and open its drawer |
| `expand` | `sec`, `regb` (comma-separated) |
| `drawer=0`, `panel=0` | close the right drawer / left panel |

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
| "Sub-30s Failover" | at the time: GA health check 10s × threshold 3 = 30s detection floor | corrected to ~30s then; **superseded in v2** — the threshold is now 1 (see below) |

Verified accurate at the time: PAN-OS 11.1.15 (path A default), `m5.xlarge`/`m5.4xlarge`,
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

## v2 update — two management paths and the path B lab (2026-10)

The viewer described only path A (Panorama, PAN-OS 11.1.15). It now reflects
the current architecture (`README.md`, `docs/DEPLOYMENT-SCM.md`, ADR D11/D12).

### Management path switch

- A **MANAGEMENT PATH** control on the diagram (top right of the edge row) and
  in the left panel (Overview) switches between **A · Panorama EC2** and
  **B · Strata Cloud Manager**. Path B is the default (it is the live,
  two-region lab); path A is unchanged and one click away. The header badge
  follows (`PAN-OS 11.1.15 · Panorama` / `PAN-OS 12.2.4+ · SCM`).
- Path A draws Panorama in the mgmt VPC and a dashed "no cloud manager" card;
  path B draws the SCM node with links to both regions' pairs, the admin panel
  in place of Panorama, and the threat-prevention card.
- Slides, flows, scenarios and drawer entries carry `mgmtPath: "A" | "B"`; opening
  one switches the diagram to that path. The LEVEL preset "Panorama & SSM" is now
  "Management" and focuses Panorama or SCM.

### New components (drawer entries + nodes)

SCM · AWS WAF (CLOUDFRONT + REGIONAL web ACLs) · CloudFront test website
(`website.<zone>`, ACM) · app NLB (CloudFront origin-facing prefix list only) ·
admin/test panel (2 AZ hosts, own ALB, AD login, live topology incl. GA health,
policy simulation, failover tests, DynamoDB history) · Guacamole browser-RDP
(ALB + TOTP, both paths) · Advanced IP Defense + Frontier Virtual Patching ·
AD CS two-tier PKI (10.13.0.20 / .21) · Region B replica DC drawer · untrust /
trust floating-IP drawers · GP client and browser-user drawers. Six new icons.
Diagram nodes without their own entry (`fw1-a`, `apache-a`, `dc-a`, …) now open
the related entry via `componentAliases` instead of doing nothing.

### Content corrections

| Was | Now |
|---|---|
| GA failover "< 30 s", threshold 3, Region B "DR standby" | both endpoint groups at **100 % traffic dial = nearest healthy region** (Poland ➔ Region A), not a split, no priority; health check **10 s × threshold 1** (~10 s detection; threshold 3 measured a 73 s portal outage) |
| HA failover: `AssociateAddress` EIP + one route | secondary-IP mode moves **untrust .100 (EIP follows) and trust .100**, `ReplaceRoute` on **both** TGW-attachment route tables; measured takeover 0.7–7.7 s, ~5 s portal outage |
| PAN-OS 11.1.15 everywhere | path B 12.2.4 minimum (image 12.2.3 ➔ in-place upgrade via SCM); path A pinned, default 11.1.15 |
| Region B TGW drawer `ASN 64513` | 64512 (the diagram was fixed earlier, the drawer was not) |

### Slides, flows, scenarios

- Slides 10 ➔ 15: new *Two management paths*, *HA failover: what moves*,
  *Path B: SCM in practice*, *Admin panel, WAF & Guacamole*, *Advanced IP Defense
  & Frontier Virtual Patching*; GA, GP, identity (replica DC + PKI) and website
  slides rewritten.
- Flows: website flow now WAF ➔ CloudFront ➔ NLB; management split into
  5A (Panorama) and 5B (SCM); new Guacamole RDP and admin-panel flows.
- Scenarios: region outage rewritten (nearest-healthy ➔ blackout ➔ one failed
  10 s check ➔ clients move ➔ GP gateway ➔ replica DC ➔ recovery, with a red
  "REGION A DOWN" veil); HA failover shows both floating IPs and the routes
  moving; new *SCM unreachable (path B)* and *WAF geo block / NLB bypass*.

### Engine fixes found while doing this

- **Label shrink-to-fit never applied**: `.node-title` / `.node-subtitle` set
  `font-size` in CSS, which beats the SVG `font-size` attribute the fit code
  wrote. Sizes are now inline styles, so long labels really shrink.
- **Scenario badge text never changed** (`setNodeBadge` looked for
  `font-size='9'`, badges are 8.5): badge text has a class now, and the pill
  widens for longer labels. Each phase re-renders, so stepping back is clean.
- **`focusOn` centred in screen pixels** inside a viewBox-scaled SVG, so focused
  nodes landed off-centre; it now centres in scene units, and presentation
  slides centre above the slide bar.
- Delayed flow particles sat visible at the scene origin before starting.
- Same-row edge links are straight lines instead of self-crossing curves; the
  default view starts lower so the LEVEL bar no longer covers the edge row.
- The narration box scrolls into view (the scenario list outgrew the panel).

### Polish data set

`js/data.js` got the same fixes, Polish slides for all 15, Polish drawer
entries for the new components and `componentAliases`. New flows and scenarios
(5B, 7, 8, 3B, 4) are not translated: a small sync at the end of
`js/data_en.js` copies any id missing from the Polish set from the English one,
so `?lang=pl` never renders a blank drawer or list item.

