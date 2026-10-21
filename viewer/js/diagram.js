/**
 * SVG Architecture Diagram Engine
 * Enterprise-grade hierarchical diagram with collapsible VPCs/regions,
 * overview/deep-dive presets, a management-path switch (A = Panorama,
 * B = Strata Cloud Manager) and bilingual (PL / EN) localization.
 *
 * Keys ending in _A / _B are path-specific; tp(key) picks the one for the
 * current management path and falls back to the plain key.
 */

const I18N_DIAGRAM = {
  pl: {
    edge_tier: "WARSTWA BRZEGOWA I WEJŚCIOWA (GLOBAL EDGE INGRESS)",
    mgmt_toggle_label: "ŚCIEŻKA ZARZĄDZANIA (D11)",
    mgmt_opt_a: "A · Panorama EC2",
    mgmt_opt_b: "B · SCM (SaaS)",
    scm_ghost_1: "Ścieżka A: brak menedżera w chmurze",
    scm_ghost_2: "Panorama EC2 (Mgmt VPC, Region A)",
    scm_ghost_3: "zarządza oboma regionami przez TGW peering",
    regionA_title: "REGION A — eu-central-1 (Frankfurt)",
    regionA_sub_A: "Centralna Panorama | Active/Passive VM-Series HA | Transit Gateway Hub | Spoke VPCs",
    regionA_sub_B: "Zarządzany z SCM | VM-Series HA (PAN-OS 12.2.4, ARE) | TGW Hub | Spoke'i | Panel admina",
    secVpc_title: "Security VPC — VM-Series HA Hub (10.10.0.0/16)",
    btn_expand_subnets: "🔍 Rozwiń Podsieci",
    btn_collapse_cluster: "▲ Zwiń do Klastra",
    cluster_title: "VM-Series Active/Passive HA Cluster",
    cluster_sub: "Pływający .100 + EIP ➔ loopback.1 (GP) | trust .100 | eth1/1 = HA2",
    cluster_desc: "Wtyczka HA przenosi pływające IP (EIP idzie za nimi) + trasy TGW · ~1–8 s",
    untrust_subnet: "Untrust Subnet (Public IGW + pływający .100 z EIP)",
    trust_subnet: "Trust Subnet (dataplane od strony TGW, pływający .100)",
    secVpc_expanded_title: "Security VPC (10.10.0.0/16) — Rozwinięte Podsieci i Interfejsy ENI",
    spoke1_note_1: "Dostępny wyłącznie przez",
    spoke1_note_2: "CloudFront ➔ WAF ➔ NLB",
    spoke1_note_3: "(SG: prefiksy CloudFront)",
    spoke1_note_4: "➔ FW DNAT ➔ :80",
    regionB_dr_tag: "DRUGI AKTYWNY REGION (NAJBLIŻSZY ZDROWY)",
    regionB_title: "REGION B — eu-west-1 (Dublin)",
    regionB_sub: "Lustrzany stack bezpieczeństwa (10.20/16)",
    regionB_h1: "✓ Global Accelerator: najbliższy zdrowy region",
    regionB_h1_sub: "Region wyłączony po 1 nieudanym teście co 10 s",
    regionB_h2: "✓ Replika DC (AD Multi-Master)",
    regionB_h2_sub: "10.23.0.10 — replikacja przez TGW peering",
    regionB_h3_A: "✓ Centralny Zarząd z Panoramy A",
    regionB_h3_sub_A: "Brak konieczności instalowania drugiej Panoramy",
    regionB_h3_B: "✓ Ten sam folder SCM co Region A",
    regionB_h3_sub_B: "Wartości regionu: zmienne per-urządzenie; HA z SCM",
    regionB_h4_A: "✓ Brama GP gw-b na portalu obu regionów",
    regionB_h4_sub_A: "Natywny wybór bramy przez agenta GP",
    regionB_h4_B: "✓ Panel admina pokazuje i testuje oba regiony",
    regionB_h4_sub_B: "Topologia na żywo z health GA, test awarii regionu",
    btn_expand_regb: "📂 Rozwiń Pełny Stack Regionu B",
    btn_collapse_regb: "✖ Zwiń B",
    regionB_exp_title: "REGION B — eu-west-1 (Dublin)",
    regionB_exp_sub: "Lustrzany stack (10.20/16) | Obsługuje najbliższych klientów | Replika DC",
    secVpcB_title: "Security VPC B (10.20.0.0/16) — Para HA B",
    regionB_highlights_title: "Architektura Odporności Regionu B",
    regionB_hl1: "✓ Identyczny moduł Terraform (region_stack)",
    regionB_hl2_A: "✓ Zarządzany z Panoramy A przez TGW Peering",
    regionB_hl2_B: "✓ Ten sam folder SCM, zmienne per-urządzenie",
    regionB_hl3: "✓ Replikacja AD po prywatnym szkielecie AWS",
    regionB_hl4: "✓ Endpoint GA (dial 100%) — najbliżsi klienci",
    regionB_hl5: "✓ Przejmuje klientów A po 1 nieudanym teście",
    regionB_hl6_A: "✓ Pełna izolacja od awarii Regionu A",
    regionB_hl6_B: "✓ Brama gw-b, pula 10.20.200.0/24"
  },
  en: {
    edge_tier: "GLOBAL EDGE & INGRESS TIER",
    mgmt_toggle_label: "MANAGEMENT PATH (D11)",
    mgmt_opt_a: "A · Panorama EC2",
    mgmt_opt_b: "B · SCM (SaaS)",
    scm_ghost_1: "Path A: no cloud manager",
    scm_ghost_2: "Panorama EC2 (Region A Mgmt VPC)",
    scm_ghost_3: "manages both regions over TGW peering",
    regionA_title: "REGION A — eu-central-1 (Frankfurt)",
    regionA_sub_A: "Central Panorama | Active/Passive VM-Series HA | Transit Gateway Hub | Spoke VPCs",
    regionA_sub_B: "Managed from SCM | Active/Passive VM-Series HA (PAN-OS 12.2.4, ARE) | TGW Hub | Spokes | Admin panel",
    secVpc_title: "Security VPC — VM-Series HA Hub (10.10.0.0/16)",
    btn_expand_subnets: "🔍 Expand Subnets",
    btn_collapse_cluster: "▲ Collapse to Cluster",
    cluster_title: "VM-Series Active/Passive HA Cluster",
    cluster_sub: "Floating .100 + EIP ➔ loopback.1 (GP) | trust .100 | eth1/1 = HA2",
    cluster_desc: "HA plugin moves floating IPs (EIP follows) + rewrites TGW routes · ~1–8 s",
    untrust_subnet: "Untrust Subnet (Public IGW + floating .100 carrying the EIP)",
    trust_subnet: "Trust Subnet (TGW-facing dataplane, floating .100)",
    secVpc_expanded_title: "Security VPC (10.10.0.0/16) — Expanded Subnets & ENI Datapaths",
    spoke1_note_1: "Reachable only via",
    spoke1_note_2: "CloudFront ➔ WAF ➔ NLB",
    spoke1_note_3: "(SG: CloudFront prefixes)",
    spoke1_note_4: "➔ FW DNAT ➔ :80",
    regionB_dr_tag: "SECOND ACTIVE REGION (NEAREST-HEALTHY)",
    regionB_title: "REGION B — eu-west-1 (Dublin)",
    regionB_sub: "Mirrored security stack (10.20/16)",
    regionB_h1: "✓ Global Accelerator: nearest healthy region",
    regionB_h1_sub: "Region marked down after 1 failed 10 s check",
    regionB_h2: "✓ Replica DC (AD Multi-Master)",
    regionB_h2_sub: "10.23.0.10 — replication over TGW peering",
    regionB_h3_A: "✓ Governed from Region A Panorama",
    regionB_h3_sub_A: "No secondary Panorama instance required",
    regionB_h3_B: "✓ Same SCM folder as Region A",
    regionB_h3_sub_B: "Region values via per-device variables; HA from SCM",
    regionB_h4_A: "✓ GP gateway gw-b on every portal",
    regionB_h4_sub_A: "GP-native gateway selection by the agent",
    regionB_h4_B: "✓ Admin panel shows & tests both regions",
    regionB_h4_sub_B: "Live topology incl. GA health, region-outage test",
    btn_expand_regb: "📂 Expand Full Region B Stack",
    btn_collapse_regb: "✖ Collapse B",
    regionB_exp_title: "REGION B — eu-west-1 (Dublin)",
    regionB_exp_sub: "Mirrored stack (10.20/16) | Serves its nearest clients | Replica DC",
    secVpcB_title: "Security VPC B (10.20.0.0/16) — HA Pair B",
    regionB_highlights_title: "Region B Resilience Highlights",
    regionB_hl1: "✓ Identical Terraform module (region_stack)",
    regionB_hl2_A: "✓ Governed by the Region A Panorama over TGW peering",
    regionB_hl2_B: "✓ Same SCM folder, per-device variables",
    regionB_hl3: "✓ AD replication over AWS private backbone",
    regionB_hl4: "✓ GA endpoint (dial 100%) — its nearest clients",
    regionB_hl5: "✓ Takes Region A's clients after 1 failed check",
    regionB_hl6_A: "✓ Complete isolation from Region A failures",
    regionB_hl6_B: "✓ Gateway gw-b, client pool 10.20.200.0/24"
  }
};

class ArchitectureDiagram {
  constructor(svgElement, data, onNodeSelected, lang = "pl") {
    this.svg = svgElement;
    this.data = data;
    this.onNodeSelected = onNodeSelected;
    this.lang = lang;

    // View state
    this.scale = 0.88;
    this.translateX = 40;
    this.translateY = 20;
    this.isPanning = false;
    this.startX = 0;
    this.startY = 0;

    // Collapsible states
    this.viewMode = "overview"; // "overview" | "deepdive"
    this.regionBCollapsed = true; // Region B starts collapsed in Overview
    this.securityVpcExpanded = false; // Security VPC starts in clean cluster card mode
    this.selectedNodeId = null;

    // Management plane: "A" = self-hosted Panorama, "B" = Strata Cloud Manager.
    // B is the live lab (both regions + panel/WAF/website); A stays one click away.
    this.mgmtPath = "B";

    // Node bounds registry for camera focusing and animation paths
    this.nodePositions = {};

    this.init();
  }

  init() {
    this.setupViewport();
    this.render();
    this.setupEventListeners();
  }

  setupViewport() {
    this.svg.setAttribute("viewBox", "0 0 1860 1060");
    this.svg.innerHTML = `
      <defs>
        <!-- Gradients -->
        <linearGradient id="grad-active-fw" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="#1E293B" />
          <stop offset="100%" stop-color="#0F172A" />
        </linearGradient>
        <linearGradient id="grad-cluster" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="rgba(30, 41, 59, 0.9)" />
          <stop offset="100%" stop-color="rgba(15, 23, 42, 0.95)" />
        </linearGradient>

        <!-- Arrow Markers -->
        <marker id="arrow-cyan" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#00F0FF" />
        </marker>
        <marker id="arrow-orange" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#FA582D" />
        </marker>
        <marker id="arrow-blue" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#38BDF8" />
        </marker>
        <marker id="arrow-green" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#10B981" />
        </marker>
        <marker id="arrow-amber" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#F59E0B" />
        </marker>
      </defs>

      <g id="scene-root">
        <g id="links-layer"></g>
        <g id="regions-layer"></g>
        <g id="vpcs-layer"></g>
        <g id="subnets-layer"></g>
        <g id="nodes-layer"></g>
        <g id="animation-layer"></g>
      </g>
    `;

    this.scene = this.svg.querySelector("#scene-root");
    this.updateTransform();
  }

  updateTransform() {
    if (this.scene) {
      this.scene.setAttribute(
        "transform",
        `translate(${this.translateX}, ${this.translateY}) scale(${this.scale})`
      );
    }
  }

  t(key) {
    const dict = I18N_DIAGRAM[this.lang] || I18N_DIAGRAM["pl"];
    return dict[key] || key;
  }

  // Path-aware lookup: "<key>_A" / "<key>_B" first, then the plain key.
  tp(key) {
    const dict = I18N_DIAGRAM[this.lang] || I18N_DIAGRAM["pl"];
    return dict[`${key}_${this.mgmtPath}`] || dict[key] || key;
  }

  isPathB() {
    return this.mgmtPath === "B";
  }

  setMgmtPath(path) {
    const p = String(path || "").toUpperCase() === "A" ? "A" : "B";
    if (p === this.mgmtPath) return false;
    this.mgmtPath = p;
    this.render();
    return true;
  }

  // Shared vertical geometry, so Region A, Region B and the collapsed card agree.
  geom() {
    const exp = this.securityVpcExpanded;
    return {
      regHeight: exp ? 900 : 700,
      tgwY: exp ? 580 : 375,
      lowerTierY: exp ? 680 : 475,
      lowerTierHeight: 330
    };
  }

  render() {
    this.clearLayers();
    this.nodePositions = {};

    // 1. Render Global Plane (Ingress / Edge Tier)
    this.renderGlobalPlane();

    // 2. Render Region A (Frankfurt)
    this.renderRegionA();

    // 3. Render Region B (Dublin)
    if (this.regionBCollapsed) {
      this.renderRegionBCollapsed();
    } else {
      this.renderRegionBExpanded();
    }

    // 4. Render Interconnects and Flow Traces
    this.renderInterconnects();
  }

  renderGlobalPlane() {
    const nodesLayer = this.svg.querySelector("#nodes-layer");
    let html = "";

    const isEn = this.lang === "en";
    const isB = this.isPathB();

    // Background tier header
    html += `
      <g transform="translate(60, 16)">
        <text fill="#64748B" font-size="11" font-weight="700" letter-spacing="0.08em">${this.t("edge_tier")}</text>
      </g>
    `;

    // GP Client
    html += this.createNodeHtml({
      id: "gp-client",
      x: 70, y: 36, w: 180, h: 68,
      title: "GlobalProtect Clients",
      sub: isEn ? "Remote users (SSL / IPSec)" : "Zdalni (SSL / IPSec)",
      icon: "user-client",
      badge: isEn ? "External" : "Klient VPN",
      badgeClass: "passive-bg"
    });

    // AWS Global Accelerator
    html += this.createNodeHtml({
      id: "global-accelerator",
      x: 266, y: 36, w: 250, h: 68,
      title: "AWS Global Accelerator",
      sub: "Anycast · dial 100/100 · HC 10s×1",
      icon: "aws-global-accelerator",
      badge: isEn ? "Nearest healthy" : "Najbliższy zdrowy",
      badgeClass: "active-bg"
    });

    // Browser users (website, panel, Guacamole)
    html += this.createNodeHtml({
      id: "web-user",
      x: 532, y: 36, w: 160, h: 68,
      title: isEn ? "Internet Users" : "Użytkownicy WWW",
      sub: isEn ? "web · panel · RDP" : "www · panel · RDP",
      icon: "user-client",
      badge: isEn ? "Browser" : "Przeglądarka",
      badgeClass: "passive-bg"
    });

    // AWS WAF (CloudFront scope + REGIONAL on the panel ALB)
    html += this.createNodeHtml({
      id: "waf",
      x: 708, y: 36, w: 170, h: 68,
      title: "AWS WAF",
      sub: isEn ? "geo PL · rate · managed" : "geo PL · limit · managed",
      icon: "aws-waf",
      badge: isEn ? "2 web ACLs" : "2 web ACL",
      badgeClass: "active-bg"
    });

    // AWS CloudFront (test website)
    html += this.createNodeHtml({
      id: "cloudfront",
      x: 894, y: 36, w: 226, h: 68,
      title: "CloudFront + ACM",
      sub: "https://website.&lt;zone&gt;",
      icon: "aws-cloudfront",
      badge: "Edge",
      badgeClass: "active-bg"
    });

    // Strata Cloud Manager (path B) or a ghost card explaining path A
    if (isB) {
      html += this.createNodeHtml({
        id: "scm",
        x: 1150, y: 36, w: 300, h: 68,
        title: "Strata Cloud Manager",
        sub: isEn ? "1 folder · 4 FWs · per-device vars" : "1 folder · 4 FW · zmienne per-FW",
        icon: "panw-scm",
        badge: isEn ? "Path B" : "Ścieżka B",
        badgeClass: "path-b-bg"
      });
    } else {
      html += `
        <g transform="translate(1150, 36)" class="ghost-card">
          <rect width="300" height="68" rx="8" fill="rgba(15,23,42,0.4)" stroke="#475569" stroke-dasharray="5 5" />
          <text x="14" y="22" fill="#94A3B8" font-size="10.5" font-weight="700">${this.t("scm_ghost_1")}</text>
          <text x="14" y="40" fill="#64748B" font-size="10">${this.t("scm_ghost_2")}</text>
          <text x="14" y="55" fill="#64748B" font-size="10">${this.t("scm_ghost_3")}</text>
        </g>
      `;
    }

    // Management path switch (A = Panorama / B = SCM)
    const optA = !isB, optB = isB;
    html += `
      <g id="mgmt-toggle" transform="translate(1470, 36)">
        <rect width="320" height="68" rx="10" fill="rgba(15,23,42,0.85)" stroke="#475569" />
        <text x="14" y="20" fill="#94A3B8" font-size="10" font-weight="700" letter-spacing="0.08em">${this.t("mgmt_toggle_label")}</text>
        <g class="btn-container-toggle mgmt-opt" transform="translate(10, 30)" onclick="window.app.setMgmtPath('A')">
          <title>Path A: self-hosted Panorama (EC2) manages both regions</title>
          <rect width="146" height="28" rx="6" fill="${optA ? '#FA582D' : '#334155'}" stroke="${optA ? '#FDBA74' : '#475569'}" />
          <text x="73" y="18" fill="${optA ? '#FFFFFF' : '#CBD5E1'}" font-size="10.5" font-weight="700" text-anchor="middle">${this.t("mgmt_opt_a")}</text>
        </g>
        <g class="btn-container-toggle mgmt-opt" transform="translate(164, 30)" onclick="window.app.setMgmtPath('B')">
          <title>Path B: Strata Cloud Manager, no Panorama EC2</title>
          <rect width="146" height="28" rx="6" fill="${optB ? '#F59E0B' : '#334155'}" stroke="${optB ? '#FDE68A' : '#475569'}" />
          <text x="73" y="18" fill="${optB ? '#0F172A' : '#CBD5E1'}" font-size="10.5" font-weight="700" text-anchor="middle">${this.t("mgmt_opt_b")}</text>
        </g>
      </g>
    `;

    nodesLayer.insertAdjacentHTML("beforeend", html);
  }

  renderRegionA() {
    const regionsLayer = this.svg.querySelector("#regions-layer");
    const vpcsLayer = this.svg.querySelector("#vpcs-layer");
    const nodesLayer = this.svg.querySelector("#nodes-layer");

    const isEn = this.lang === "en";
    const isB = this.isPathB();
    const isSecExpanded = this.securityVpcExpanded;
    const { regHeight, tgwY, lowerTierY, lowerTierHeight } = this.geom();

    // Region Box
    regionsLayer.insertAdjacentHTML("beforeend", `
      <rect id="region-a" class="region-box region-a" x="60" y="130" width="860" height="${regHeight}" />
      <g transform="translate(84, 160)">
        <text class="region-label">${this.t("regionA_title")}</text>
        <text class="region-sublabel" y="18">${this.tp("regionA_sub")}</text>
      </g>
    `);

    // ==========================================
    // 1. SECURITY VPC
    // ==========================================
    if (!isSecExpanded) {
      // --- COLLAPSED SECURITY VPC (Clean Overview Cluster Card) ---
      vpcsLayer.insertAdjacentHTML("beforeend", `
        <rect class="vpc-box security-vpc" x="84" y="195" width="762" height="150" />
        <text class="vpc-title" x="104" y="220">${this.t("secVpc_title")}</text>
        <g class="btn-container-toggle" transform="translate(710, 204)" onclick="window.app.toggleSecurityVpc()">
          <rect width="124" height="24" rx="4" fill="#334155" />
          <text x="62" y="16" fill="#38BDF8" font-size="10.5" font-weight="700" text-anchor="middle">${this.t("btn_expand_subnets")}</text>
        </g>
      `);

      // Path B adds a threat-prevention card beside a narrower cluster card.
      const cw = isB ? 520 : 722;

      // Unified HA Cluster Card
      nodesLayer.insertAdjacentHTML("beforeend", `
        <g id="node-fw-pair-a" class="arch-node" transform="translate(104, 235)" onclick="window.app.selectComponent('fw-pair-a')">
          <rect class="cluster-overview-card" width="${cw}" height="92" rx="10" />
          <g transform="translate(16, 16)">
            <g class="node-icon">${ICONS["panw-vmseries"]}</g>
            <text fill="#FFFFFF" font-size="13" font-weight="700" x="48" y="18">${this.t("cluster_title")}</text>
            <text fill="#94A3B8" font-size="10.5" font-family="var(--font-mono)" x="48" y="36">${this.t("cluster_sub")}</text>
            <text fill="#64748B" font-size="10.5" x="48" y="54">${this.t("cluster_desc")}</text>
          </g>
          <g transform="translate(${cw - 162}, 16)">
            <rect width="70" height="20" rx="4" fill="rgba(16,185,129,0.2)" stroke="#10B981" />
            <text x="35" y="14" fill="#10B981" font-size="9.5" font-weight="700" text-anchor="middle">FW1: ACTIVE</text>
          </g>
          <g transform="translate(${cw - 86}, 16)">
            <rect width="72" height="20" rx="4" fill="rgba(100,116,139,0.2)" stroke="#64748B" />
            <text x="36" y="14" fill="#94A3B8" font-size="9.5" font-weight="700" text-anchor="middle">FW2: PASSIVE</text>
          </g>
        </g>
      `);

      if (isB) {
        nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
          id: "threat-prevention",
          x: 640, y: 235, w: 186, h: 92,
          title: "Threat Prevention",
          sub: "Adv. IP Defense<br/>Frontier Virtual Patching",
          icon: "panw-threat",
          badge: "12.2.4+",
          badgeClass: "path-b-bg"
        }));
      }

      // Map internal nodes to the cluster center for flow animations
      const cx = 104 + cw / 2;
      this.nodePositions["fw-pair-a"] = { x: 104, y: 235, w: cw, h: 92, cx, cy: 281 };
      this.nodePositions["untrust-a"] = { cx: 104 + cw * 0.22, cy: 281, x: 110, y: 240, w: cw * 0.4, h: 80 };
      this.nodePositions["nlb-a"] = { cx: 104 + cw * 0.78, cy: 281, x: 104 + cw * 0.56, y: 240, w: cw * 0.4, h: 80 };
      this.nodePositions["fw1-a"] = { cx: 104 + cw * 0.22, cy: 281, x: 110, y: 240, w: cw * 0.4, h: 80 };
      this.nodePositions["fw2-a"] = { cx: 104 + cw * 0.78, cy: 281, x: 104 + cw * 0.56, y: 240, w: cw * 0.4, h: 80 };
      this.nodePositions["trust-a"] = { cx, cy: 320, x: 104, y: 280, w: cw, h: 40 };

    } else {
      // --- EXPANDED SECURITY VPC (Deep-Dive Subnets & ENIs) ---
      vpcsLayer.insertAdjacentHTML("beforeend", `
        <rect class="vpc-box security-vpc" x="84" y="195" width="762" height="360" />
        <text class="vpc-title" x="104" y="220">${this.t("secVpc_expanded_title")}</text>
        <g class="btn-container-toggle" transform="translate(730, 204)" onclick="window.app.toggleSecurityVpc()">
          <rect width="104" height="24" rx="4" fill="#334155" />
          <text x="52" y="16" fill="#F8FAFC" font-size="10.5" font-weight="700" text-anchor="middle">${this.t("btn_collapse_cluster")}</text>
        </g>

        <!-- Untrust Subnet -->
        <rect class="subnet-box" x="100" y="235" width="730" height="80" />
        <text class="subnet-label" x="114" y="253">${this.t("untrust_subnet")}</text>
        <text class="subnet-cidr" text-anchor="end" x="816" y="253">10.10.10.0/24</text>

        <!-- Trust Subnet -->
        <rect class="subnet-box" x="100" y="464" width="730" height="80" />
        <text class="subnet-label" x="114" y="482">${this.t("trust_subnet")}</text>
        <text class="subnet-cidr" text-anchor="end" x="816" y="482">10.10.20.0/24</text>
      `);

      // Untrust Floating IP + EIP
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "untrust-a",
        x: 114, y: 265, w: 340, h: 42,
        title: isEn ? "Untrust Floating IP .100 + EIP" : "Pływający IP .100 + EIP (untrust)",
        sub: isEn ? "loopback.1 | GP portal & gw-a | moves on failover" : "loopback.1 | portal GP & gw-a | przenoszony przy awarii",
        icon: "panw-globalprotect",
        badge: "Elastic IP",
        badgeClass: "active-bg"
      }));

      // App NLB
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "nlb-a",
        x: 476, y: 265, w: 340, h: 42,
        title: "App NLB (website origin)",
        sub: isEn ? "SG: CloudFront prefix list | ➔ .100:80 DNAT" : "SG: prefiksy CloudFront | ➔ .100:80 DNAT",
        icon: "aws-nlb",
        badge: "Dual-AZ",
        badgeClass: "active-bg"
      }));

      // FW1 Active Node
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "fw1-a",
        x: 114, y: 330, w: 340, h: 114,
        title: "VM-Series FW1 (Active)",
        sub: isEn ? "Holds floating IPs + EIP | m5.xlarge" : "Trzyma pływające IP + EIP | m5.xlarge",
        icon: "panw-vmseries",
        badge: "ACTIVE",
        badgeClass: "active-bg",
        customCardClass: "fw-active",
        detailsSnippet: "eth0(mgmt) • eth1(ha2) • eth2(trust) • eth3(untrust)"
      }));

      // FW2 Passive Node
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "fw2-a",
        x: 476, y: 330, w: 340, h: 114,
        title: "VM-Series FW2 (Passive)",
        sub: isEn ? "Preemption: OFF | Standby" : "Preemption: WYŁ. | Standby",
        icon: "panw-vmseries",
        badge: "PASSIVE",
        badgeClass: "passive-bg",
        customCardClass: "fw-passive",
        detailsSnippet: "eth0(mgmt) • eth1(ha2) • eth2(trust) • eth3(untrust)"
      }));

      // Trust Interface Box
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "trust-a",
        x: 114, y: 494, w: 702, h: 42,
        title: isEn ? "Trust ENI & Inspection Gateway (ethernet1/2, floating .100)" : "Trust ENI & Brama Inspekcyjna (ethernet1/2, pływający .100)",
        sub: isEn ? "TGW-attachment routes 0.0.0.0/0 ➔ active unit's trust ENI | HA plugin ReplaceRoute" : "Trasy TGW-attachment 0.0.0.0/0 ➔ trust ENI aktywnego FW | ReplaceRoute",
        icon: "aws-transit-gateway",
        badge: "TGW Facing",
        badgeClass: "active-bg"
      }));

      this.nodePositions["fw-pair-a"] = { x: 114, y: 330, w: 702, h: 114, cx: 465, cy: 387 };
      // Threat prevention is a property of the pair; in this view it maps onto it.
      if (isB) this.nodePositions["threat-prevention"] = { ...this.nodePositions["fw-pair-a"] };
    }

    // ==========================================
    // 2. TRANSIT GATEWAY A
    // ==========================================
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "tgw-a",
      x: 230, y: tgwY, w: 470, h: 66,
      title: "Transit Gateway Region A (ASN 64512)",
      sub: isEn ? "Appliance Mode: ENABLED (Cross-AZ Symmetry Hub)" : "Appliance Mode: WŁĄCZONY (Symetria stref AZ)",
      icon: "aws-transit-gateway",
      badge: isEn ? "Central Hub" : "Główny Hub",
      badgeClass: "active-bg"
    }));

    // ==========================================
    // 3. MANAGEMENT VPC & SPOKES
    // ==========================================

    // Management VPC
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box mgmt-vpc" x="84" y="${lowerTierY}" width="370" height="${lowerTierHeight}" />
      <text class="vpc-title" x="104" y="${lowerTierY + 22}">Management VPC</text>
      <text class="vpc-cidr" text-anchor="end" x="440" y="${lowerTierY + 22}">10.11.0.0/16</text>
    `);

    // Slot 1: Panorama (path A) or the admin/test panel (path B)
    if (isB) {
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "admin-panel",
        x: 104, y: lowerTierY + 36, w: 330, h: 84,
        title: isEn ? "Admin / Test Panel" : "Panel Admina / Testów",
        sub: isEn
          ? "panel.&lt;zone&gt; · own ALB + WAF<br/>2 hosts (AZ a/b) · AD login<br/>Failover tests · DynamoDB history"
          : "panel.&lt;zone&gt; · własny ALB + WAF<br/>2 hosty (AZ a/b) · logowanie AD<br/>Testy awarii · historia DynamoDB",
        icon: "panel-dashboard",
        badge: isEn ? "Path B" : "Ścieżka B",
        badgeClass: "path-b-bg"
      }));
    } else {
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "panorama",
        x: 104, y: lowerTierY + 36, w: 330, h: 84,
        title: "Panorama Central Management",
        sub: isEn
          ? "10.11.0.10 | m5.4xlarge | 2TB Log EBS<br/>Template stack + device group<br/>Manages both regions (TGW peering)"
          : "10.11.0.10 | m5.4xlarge | 2TB EBS na Logi<br/>Template stack + device group<br/>Zarządza oboma regionami (TGW)",
        icon: "panw-panorama",
        badge: isEn ? "Path A" : "Ścieżka A",
        badgeClass: "path-a-bg"
      }));
    }

    // Slot 2: SSM Jump Host
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "ssm-jumphost",
      x: 104, y: lowerTierY + 130, w: 330, h: 84,
      title: "SSM Jump Host (Zero-Bastion)",
      sub: isEn
        ? "No public ports | SSM port-forwarding<br/>XML API / SSH to the firewalls"
        : "Brak publicznych portów | tunel SSM<br/>XML API / SSH do firewalli",
      icon: "aws-ssm",
      badge: "SSM Tunnel",
      badgeClass: "active-bg"
    }));

    // Slot 3: Guacamole (both paths)
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "guacamole",
      x: 104, y: lowerTierY + 224, w: 330, h: 84,
      title: isEn ? "Guacamole Browser-RDP" : "Guacamole RDP w przeglądarce",
      sub: isEn
        ? "rdp.&lt;zone&gt; · ALB + mandatory TOTP<br/>RDP ➔ DC through the firewalls"
        : "rdp.&lt;zone&gt; · ALB + obowiązkowe TOTP<br/>RDP ➔ DC przez firewalle",
      icon: "guacamole-rdp",
      badge: isEn ? "Both paths" : "Obie ścieżki",
      badgeClass: "active-bg"
    }));

    // Spoke 1 (Apache / test website origin)
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box spoke-vpc" x="474" y="${lowerTierY}" width="200" height="${lowerTierHeight}" />
      <text class="vpc-title" x="488" y="${lowerTierY + 22}">Spoke 1 (App)</text>
      <text class="vpc-cidr" text-anchor="end" x="660" y="${lowerTierY + 22}">10.12/16</text>
    `);

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "apache-a",
      x: 488, y: lowerTierY + 36, w: 172, h: 130,
      title: "Apache Web App",
      sub: isEn ? "10.12.0.10<br/>website origin<br/>Port 80 (DNAT)" : "10.12.0.10<br/>origin strony<br/>Port 80 (DNAT)",
      icon: "aws-ec2",
      badge: "EC2 App",
      badgeClass: "active-bg"
    }));

    nodesLayer.insertAdjacentHTML("beforeend", `
      <g transform="translate(488, ${lowerTierY + 182})">
        <rect width="172" height="126" rx="8" fill="rgba(15,23,42,0.55)" stroke="#334155" stroke-dasharray="4 4" />
        <text x="12" y="26" fill="#94A3B8" font-size="10" font-weight="700">${this.t("spoke1_note_1")}</text>
        <text x="12" y="50" fill="#CBD5E1" font-size="10">${this.t("spoke1_note_2")}</text>
        <text x="12" y="70" fill="#64748B" font-size="9.5">${this.t("spoke1_note_3")}</text>
        <text x="12" y="94" fill="#CBD5E1" font-size="10">${this.t("spoke1_note_4")}</text>
      </g>
    `);

    // Spoke 2 (Active Directory + PKI)
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box spoke-vpc" x="694" y="${lowerTierY}" width="200" height="${lowerTierHeight}" />
      <text class="vpc-title" x="708" y="${lowerTierY + 22}">Spoke 2 (AD DS)</text>
      <text class="vpc-cidr" text-anchor="end" x="880" y="${lowerTierY + 22}">10.13/16</text>
    `);

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "dc-a",
      x: 708, y: lowerTierY + 36, w: 172, h: 130,
      title: isEn ? "Windows DC (Primary)" : "Windows DC (Podstawowy)",
      sub: "panw.labs<br/>10.13.0.10<br/>LDAP · DNS",
      icon: "aws-directory-service",
      badge: "Forest Root",
      badgeClass: "active-bg"
    }));

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "pki",
      x: 708, y: lowerTierY + 178, w: 172, h: 130,
      title: "AD CS PKI (2-tier)",
      sub: isEn ? "Root CA 10.13.0.20<br/>Issuing CA 10.13.0.21<br/>GP pre-logon certs" : "Root CA 10.13.0.20<br/>Issuing CA 10.13.0.21<br/>Certy GP pre-logon",
      icon: "pki-cert",
      badge: "PKI",
      badgeClass: "active-bg"
    }));
  }

  renderRegionBCollapsed() {
    const regionsLayer = this.svg.querySelector("#regions-layer");
    const { regHeight } = this.geom();

    regionsLayer.insertAdjacentHTML("beforeend", `
      <g id="region-b" transform="translate(980, 130)">
        <rect class="collapsed-card" width="360" height="${regHeight}" rx="14" />

        <g transform="translate(24, 32)">
          <text fill="#FA582D" font-size="10.5" font-weight="700" letter-spacing="0.05em">${this.t("regionB_dr_tag")}</text>
          <text fill="#FFFFFF" font-size="15" font-weight="700" y="24">${this.t("regionB_title")}</text>
          <text fill="#94A3B8" font-size="11.5" y="44">${this.t("regionB_sub")}</text>
        </g>

        <!-- Highlights List -->
        <g transform="translate(24, 100)">
          <rect width="312" height="198" rx="8" fill="rgba(15,23,42,0.6)" stroke="#334155" />
          <text x="14" y="26" fill="#38BDF8" font-size="11" font-weight="700">${this.t("regionB_h1")}</text>
          <text x="14" y="44" fill="#94A3B8" font-size="10.5">${this.t("regionB_h1_sub")}</text>

          <text x="14" y="72" fill="#38BDF8" font-size="11" font-weight="700">${this.t("regionB_h2")}</text>
          <text x="14" y="90" fill="#94A3B8" font-size="10.5">${this.t("regionB_h2_sub")}</text>

          <text x="14" y="118" fill="#38BDF8" font-size="11" font-weight="700">${this.tp("regionB_h3")}</text>
          <text x="14" y="136" fill="#94A3B8" font-size="10.5">${this.tp("regionB_h3_sub")}</text>

          <text x="14" y="164" fill="#38BDF8" font-size="11" font-weight="700">${this.tp("regionB_h4")}</text>
          <text x="14" y="182" fill="#94A3B8" font-size="10.5">${this.tp("regionB_h4_sub")}</text>
        </g>

        <!-- Big Expand Action Button -->
        <g class="btn-container-toggle" transform="translate(24, 320)" onclick="window.app.toggleRegionB()">
          <rect width="312" height="46" rx="8" fill="#FA582D" />
          <text x="156" y="28" fill="#FFFFFF" font-size="13" font-weight="700" text-anchor="middle">${this.t("btn_expand_regb")}</text>
        </g>
      </g>
    `);

    // Register virtual anchor targets for Region B interconnects
    const centerY = 130 + regHeight / 2;
    this.nodePositions["untrust-b"] = { cx: 1160, cy: 180, x: 1000, y: 150, w: 320, h: 60 };
    this.nodePositions["fw-pair-b"] = { cx: 1160, cy: 260, x: 1000, y: 220, w: 320, h: 80 };
    this.nodePositions["fw1-b"] = { cx: 1160, cy: 260, x: 1000, y: 220, w: 320, h: 80 };
    this.nodePositions["tgw-b"] = { cx: 1160, cy: centerY, x: 1000, y: centerY - 30, w: 320, h: 60 };
    this.nodePositions["dc-b"] = { cx: 1160, cy: centerY + 140, x: 1000, y: centerY + 110, w: 320, h: 60 };
  }

  renderRegionBExpanded() {
    const regionsLayer = this.svg.querySelector("#regions-layer");
    const vpcsLayer = this.svg.querySelector("#vpcs-layer");
    const nodesLayer = this.svg.querySelector("#nodes-layer");

    const isEn = this.lang === "en";
    const isB = this.isPathB();
    const { regHeight, tgwY, lowerTierY, lowerTierHeight } = this.geom();

    // Region B Box
    regionsLayer.insertAdjacentHTML("beforeend", `
      <rect id="region-b" class="region-box region-b" x="980" y="130" width="810" height="${regHeight}" />
      <g transform="translate(1004, 160)">
        <text class="region-label">${this.t("regionB_exp_title")}</text>
        <text class="region-sublabel" y="18">${this.t("regionB_exp_sub")}</text>
      </g>
      <g class="btn-container-toggle" transform="translate(1676, 144)" onclick="window.app.toggleRegionB()">
        <rect width="90" height="24" rx="4" fill="#334155" />
        <text x="45" y="16" fill="#F8FAFC" font-size="10.5" font-weight="700" text-anchor="middle">${this.t("btn_collapse_regb")}</text>
      </g>
    `);

    // Security VPC B
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box security-vpc" x="1004" y="195" width="762" height="150" />
      <text class="vpc-title" x="1024" y="220">${this.t("secVpcB_title")}</text>
    `);

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "untrust-b",
      x: 1024, y: 235, w: 350, h: 90,
      title: isEn ? "Untrust Floating IP .100 + EIP (B)" : "Pływający IP .100 + EIP (B)",
      sub: isEn ? "Portal + gw-b | GA endpoint, dial 100%<br/>10.20.10.100 ➔ loopback.1" : "Portal + gw-b | endpoint GA, dial 100%<br/>10.20.10.100 ➔ loopback.1",
      icon: "panw-globalprotect",
      badge: isEn ? "GA Endpoint" : "Endpoint GA",
      badgeClass: "active-bg"
    }));

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "fw1-b",
      x: 1394, y: 235, w: 350, h: 90,
      title: isEn ? "VM-Series FW Pair B" : "Para VM-Series Region B",
      sub: isB
        ? (isEn ? "FW1 (Active) / FW2 (Passive)<br/>Same SCM folder · per-device vars" : "FW1 (Active) / FW2 (Passive)<br/>Ten sam folder SCM · zmienne per-FW")
        : (isEn ? "FW1 (Active) / FW2 (Passive)<br/>Managed by Panorama in Region A" : "FW1 (Active) / FW2 (Passive)<br/>Zarządzana z Panoramy w Regionie A"),
      icon: "panw-vmseries",
      badge: isEn ? "Active pair" : "Aktywna para",
      badgeClass: "active-bg"
    }));
    this.nodePositions["fw-pair-b"] = { ...this.nodePositions["fw1-b"] };

    // TGW B
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "tgw-b",
      x: 1150, y: tgwY, w: 470, h: 66,
      title: "Transit Gateway Region B (ASN 64512)",
      sub: isEn ? "Peering Accepter to Region A TGW (Appliance Mode Enabled)" : "Akceptor Peer-ingu do TGW A (Appliance Mode Włączony)",
      icon: "aws-transit-gateway",
      badge: isEn ? "Region B Hub" : "Hub B",
      badgeClass: "active-bg"
    }));

    // Replica DC B
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box spoke-vpc" x="1004" y="${lowerTierY}" width="370" height="${lowerTierHeight}" />
      <text class="vpc-title" x="1024" y="${lowerTierY + 22}">Spoke 2 (Replica DC)</text>
      <text class="vpc-cidr" text-anchor="end" x="1360" y="${lowerTierY + 22}">10.23/16</text>
    `);

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "dc-b",
      x: 1024, y: lowerTierY + 36, w: 330, h: 150,
      title: isEn ? "Windows DC Replica" : "Windows DC (Replika)",
      sub: isEn
        ? "panw.labs (additional DC)<br/>10.23.0.10<br/>AD replication: 0 failures both ways<br/>Primary DNS for gw-b clients"
        : "panw.labs (dodatkowy DC)<br/>10.23.0.10<br/>Replikacja AD: 0 błędów w obie strony<br/>Główny DNS klientów gw-b",
      icon: "aws-directory-service",
      badge: "AD Replication",
      badgeClass: "active-bg"
    }));

    // Info panel in Region B
    nodesLayer.insertAdjacentHTML("beforeend", `
      <g transform="translate(1394, ${lowerTierY})">
        <rect width="372" height="${lowerTierHeight}" rx="10" fill="rgba(30,41,59,0.5)" stroke="#334155" />
        <text x="18" y="28" fill="#E2E8F0" font-size="12" font-weight="700">${this.t("regionB_highlights_title")}</text>
        <text x="18" y="58" fill="#94A3B8" font-size="11">${this.t("regionB_hl1")}</text>
        <text x="18" y="84" fill="#94A3B8" font-size="11">${this.tp("regionB_hl2")}</text>
        <text x="18" y="110" fill="#94A3B8" font-size="11">${this.t("regionB_hl3")}</text>
        <text x="18" y="136" fill="#94A3B8" font-size="11">${this.t("regionB_hl4")}</text>
        <text x="18" y="162" fill="#94A3B8" font-size="11">${this.t("regionB_hl5")}</text>
        <text x="18" y="188" fill="#94A3B8" font-size="11">${this.tp("regionB_hl6")}</text>
      </g>
    `);
  }

  renderInterconnects() {
    const linksLayer = this.svg.querySelector("#links-layer");
    const isB = this.isPathB();
    let html = "";

    // Same-row neighbours get a straight horizontal link (right edge ➔ left
    // edge). A bottom➔top curve between two cards on one row loops back on
    // itself and crosses the cards.
    const rowLink = (a, b, opts) => {
      const p1 = this.nodePositions[a];
      const p2 = this.nodePositions[b];
      if (!p1 || !p2) return "";
      return this.createDirectLink(p1.x + p1.w, p1.cy, p2.x, p2.cy, opts);
    };

    // 1. Client ➔ Global Accelerator
    html += rowLink("gp-client", "global-accelerator", { stroke: "#38BDF8", dashed: true });

    // 2./3. GA ➔ both regions. Both endpoint groups run at a 100% traffic dial:
    // each client goes to its NEAREST HEALTHY region, so both links are live.
    html += this.createLinkPath("global-accelerator", "untrust-a", { stroke: "#00F0FF", marker: "arrow-cyan" });
    html += this.createLinkPath("global-accelerator", "untrust-b", { stroke: "#00F0FF", marker: "arrow-cyan" });

    // 4. Browser users ➔ WAF ➔ CloudFront ➔ app NLB A
    html += rowLink("web-user", "waf", { stroke: "#FA582D" });
    html += rowLink("waf", "cloudfront", { stroke: "#FA582D" });
    html += this.createLinkPath("cloudfront", "nlb-a", { stroke: "#FA582D", marker: "arrow-orange" });

    // Path B: WAF (REGIONAL web ACL) also fronts the panel ALB; SCM manages
    // both regions' pairs from one folder.
    if (isB) {
      html += this.createLinkPath("waf", "admin-panel", { stroke: "#F59E0B", dashed: true, strokeWidth: 1.5 });
      html += this.createLinkPath("scm", "fw-pair-a", { stroke: "#F59E0B", dashed: true, marker: "arrow-amber" });
      html += this.createLinkPath("scm", "fw-pair-b", { stroke: "#F59E0B", dashed: true, marker: "arrow-amber" });
    }

    // If Security VPC is expanded, draw HA sync and internal interfaces
    if (this.securityVpcExpanded) {
      // HA1 & HA2 links between FW1 and FW2
      const fw1 = this.nodePositions["fw1-a"];
      const fw2 = this.nodePositions["fw2-a"];
      if (fw1 && fw2) {
        // HA1 Heartbeat (Top line)
        html += this.createDirectLink(fw1.x + fw1.w, fw1.y + 35, fw2.x, fw2.y + 35, {
          stroke: "#38BDF8",
          dashed: true,
          class: "ha-link"
        });
        // HA2 State Sync (Bottom line)
        html += this.createDirectLink(fw1.x + fw1.w, fw1.y + 75, fw2.x, fw2.y + 75, {
          stroke: "#FA582D",
          class: "ha-link"
        });
      }

      // FW1/FW2 down to Trust ENI
      const trust = this.nodePositions["trust-a"];
      if (fw1 && trust) {
        html += this.createDirectLink(fw1.cx, fw1.y + fw1.h, fw1.cx, trust.y, { stroke: "#475569" });
      }
      if (fw2 && trust) {
        html += this.createDirectLink(fw2.cx, fw2.y + fw2.h, fw2.cx, trust.y, { stroke: "#475569" });
      }
    }

    // Security VPC / Cluster ➔ TGW A
    const secTarget = this.securityVpcExpanded ? "trust-a" : "fw-pair-a";
    html += this.createLinkPath(secTarget, "tgw-a", { stroke: "#FF9900", strokeWidth: 3 });

    // TGW A ➔ Spokes & Mgmt
    html += this.createLinkPath("tgw-a", isB ? "admin-panel" : "panorama", { stroke: "#38BDF8" });
    html += this.createLinkPath("tgw-a", "apache-a", { stroke: "#A855F7" });
    html += this.createLinkPath("tgw-a", "dc-a", { stroke: "#3B82F6" });

    // Cross-Region TGW Peering Backbone (TGW A ⇄ TGW B)
    const tgwA = this.nodePositions["tgw-a"];
    const tgwB = this.nodePositions["tgw-b"];
    if (tgwA && tgwB) {
      html += this.createDirectLink(tgwA.x + tgwA.w, tgwA.cy, tgwB.x, tgwB.cy, {
        stroke: "#38BDF8",
        strokeWidth: 3,
        class: "peering-link",
        id: "link-tgw-peering"
      });
      // Animation anchor for the peering itself (midpoint of the link).
      const mx = (tgwA.x + tgwA.w + tgwB.x) / 2;
      const my = (tgwA.cy + tgwB.cy) / 2;
      this.nodePositions["tgw-peering"] = { cx: mx, cy: my, x: mx - 20, y: my - 20, w: 40, h: 40 };
    }

    // Active Directory Replication (DC A ⇄ DC B)
    const dcA = this.nodePositions["dc-a"];
    const dcB = this.nodePositions["dc-b"];
    if (dcA && dcB) {
      html += this.createDirectLink(dcA.x + dcA.w, dcA.cy, dcB.x, dcB.cy, {
        stroke: "#EC4899",
        strokeWidth: 2,
        dashed: true,
        id: "link-ad-replication"
      });
    }

    linksLayer.innerHTML = html;
  }

  createNodeHtml(cfg) {
    const iconSvg = ICONS[cfg.icon] || ICONS["aws-logo"];
    const cardClass = cfg.customCardClass || "";

    // Register position for animations & camera
    this.nodePositions[cfg.id] = {
      x: cfg.x,
      y: cfg.y,
      w: cfg.w,
      h: cfg.h,
      cx: cfg.x + cfg.w / 2,
      cy: cfg.y + cfg.h / 2
    };

    // --- Fitting title, subtitle and badge inside the card -----------------
    // Three real overflow bugs this replaces:
    //   * the badge was a fixed 80px block pinned right while the title started
    //     at a fixed offset, leaving w-152 px for the title — 0 px on the 152px
    //     spoke nodes, so titles ran under the badge and out of the card;
    //   * subtitles sat at y=42 absolute inside cards only 42px tall, so the
    //     second line rendered ON the bottom border ("loopback.1 | GP Portal");
    //   * long subtitles simply ran past the right edge ("... Panorama A").
    // Rather than truncate first, SHRINK to fit: a slightly smaller label is far
    // more useful than an ellipsis. Only clip when even the floor size overflows.
    const CH_TITLE = 0.56;  // width per char, as a fraction of font-size, 700 weight
    const CH_MONO  = 0.60;  // monospace subtitle
    const esc = (v) => String(v == null ? "" : v);
    // Entities such as &lt; render as one glyph; measure them as one.
    const vlen = (s) => s.replace(/&[a-z#0-9]+;/gi, "_").length;

    const titleText = esc(cfg.title);
    const badgeText = esc(cfg.badge);
    // Upstream encodes multi-line subtitles with <br/>, which SVG does not
    // honour — the extra lines silently vanished. Split and emit real tspans.
    const subLines = esc(cfg.sub).split(/<br\s*\/?>/i).filter(Boolean);

    const badgeFont = 8.5;
    const badgeW = badgeText ? Math.max(46, Math.round(vlen(badgeText) * badgeFont * 0.62) + 16) : 0;

    // Park the badge on a bottom row whenever it would squeeze the title, and
    // the card is tall enough to host a second row (>=60px). This is what saves
    // the narrow cards: on a 200px card a 13-char badge eats 85px of width, so
    // inline there is no room for the title at any legible size, while stacked
    // the title gets the full 136px and renders at full 11px.
    const stackBadge = Boolean(badgeText) && cfg.h >= 60 &&
      vlen(titleText) * 11 * CH_TITLE > cfg.w - 54 - badgeW - 18;

    const titleRoom = (stackBadge ? cfg.w - 64 : cfg.w - 54 - (badgeW ? badgeW + 18 : 12));
    const subRoom   = cfg.w - 54 - 12;

    const fit = (text, room, max, min, ratio) => {
      if (!text) return { size: max, text: "" };
      let size = max;
      while (size > min && vlen(text) * size * ratio > room) size -= 0.5;
      if (vlen(text) * size * ratio > room) {
        const keep = Math.max(3, Math.floor(room / (size * ratio)) - 1);
        return { size, text: text.slice(0, keep).trimEnd() + "…" };
      }
      return { size, text };
    };

    const t  = fit(titleText, titleRoom, 11, 7.5, CH_TITLE);
    const ss = subLines.map(l => fit(l, subRoom, 9.5, 7.5, CH_MONO));
    const subSize = ss.length ? Math.min(...ss.map(x => x.size)) : 9.5;

    // Vertical layout. The inner group is translated by (12,10), so a baseline
    // of Y here sits at Y+10 in card space; the card must fit the last baseline
    // plus a descender. Short cards get a tighter rhythm instead of overflowing.
    // A stacked badge occupies the bottom 26px, so a short card must also pull
    // its text rows up or the subtitle lands underneath the badge.
    const tight     = cfg.h < 56 || (stackBadge && cfg.h < 90);
    const titleBase = tight ? 12 : 16;
    const lineGap   = tight ? 12 : 15;

    const subMarkup = ss.map((x, i) =>
      `<text class="node-subtitle" font-size="${subSize}" x="42" y="${titleBase + lineGap * (i + 1)}">${x.text}</text>`
    ).join("");

    const badgeMarkup = !badgeText ? "" : stackBadge
      ? `<rect class="node-badge ${cfg.badgeClass || ''}" x="12" y="${cfg.h - 26}" width="${badgeW}" height="18" rx="4" />
         <text class="node-badge-text" fill="#FFFFFF" font-size="${badgeFont}" font-weight="700" x="${12 + badgeW / 2}" y="${cfg.h - 13}" text-anchor="middle">${badgeText}</text>`
      : `<rect class="node-badge ${cfg.badgeClass || ''}" x="${cfg.w - badgeW - 10}" y="8" width="${badgeW}" height="18" rx="4" />
         <text class="node-badge-text" fill="#FFFFFF" font-size="${badgeFont}" font-weight="700" x="${cfg.w - badgeW / 2 - 10}" y="20" text-anchor="middle">${badgeText}</text>`;

    const snippetY = titleBase + lineGap * (ss.length + 1);

    return `
      <g id="node-${cfg.id}" class="arch-node" transform="translate(${cfg.x}, ${cfg.y})" onclick="window.app.selectComponent('${cfg.id}')">
        <rect class="node-card ${cardClass}" width="${cfg.w}" height="${cfg.h}" />
        <g transform="translate(12, 10)">
          <g class="node-icon">${iconSvg}</g>
          <text class="node-title" font-size="${t.size}" x="42" y="${titleBase}">${t.text}<title>${titleText}</title></text>
          ${subMarkup}
          ${cfg.detailsSnippet ? `<text fill="#64748B" font-size="9" font-family="var(--font-mono)" x="42" y="${snippetY}">${cfg.detailsSnippet}</text>` : ''}
        </g>
        ${badgeMarkup}
      </g>
    `;
  }

  createDirectLink(x1, y1, x2, y2, opts = {}) {
    const stroke = opts.stroke || "#475569";
    const width = opts.strokeWidth || 2;
    const dash = opts.dashed ? "stroke-dasharray='5 5'" : "";
    const extraClass = opts.class || "";
    const id = opts.id ? `id='${opts.id}'` : "";
    const marker = opts.marker ? `marker-end="url(#${opts.marker})"` : "";

    return `
      <line ${id} class="arch-link ${extraClass}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}"
        stroke="${stroke}" stroke-width="${width}" ${dash} ${marker} />
    `;
  }

  createLinkPath(sourceId, targetId, opts = {}) {
    const p1 = this.nodePositions[sourceId];
    const p2 = this.nodePositions[targetId];
    if (!p1 || !p2) return "";

    const x1 = p1.cx;
    const y1 = p1.y + p1.h;
    const x2 = p2.cx;
    const y2 = p2.y;
    const midY = (y1 + y2) / 2;

    const d = `M ${x1} ${y1} C ${x1} ${midY}, ${x2} ${midY}, ${x2} ${y2}`;
    const stroke = opts.stroke || "#475569";
    const strokeW = opts.strokeWidth || 2;
    const dash = opts.dashed ? "stroke-dasharray='5 5'" : "";
    const marker = opts.marker ? `marker-end="url(#${opts.marker})"` : "";

    return `
      <path class="arch-link" d="${d}" stroke="${stroke}" stroke-width="${strokeW}" fill="none" ${dash} ${marker} />
    `;
  }

  setupEventListeners() {
    // Pan & Drag Handlers
    this.svg.addEventListener("mousedown", (e) => {
      if (e.target.closest(".arch-node") || e.target.closest(".btn-container-toggle")) return;
      this.isPanning = true;
      this.startX = e.clientX - this.translateX;
      this.startY = e.clientY - this.translateY;
    });

    window.addEventListener("mousemove", (e) => {
      if (!this.isPanning) return;
      this.translateX = e.clientX - this.startX;
      this.translateY = e.clientY - this.startY;
      this.updateTransform();
    });

    window.addEventListener("mouseup", () => {
      this.isPanning = false;
    });

    // Zoom Handlers
    this.svg.addEventListener("wheel", (e) => {
      e.preventDefault();
      const zoomFactor = 1.1;
      if (e.deltaY < 0) {
        this.zoom(zoomFactor, e.clientX, e.clientY);
      } else {
        this.zoom(1 / zoomFactor, e.clientX, e.clientY);
      }
    }, { passive: false });
  }

  zoom(factor, clientX, clientY) {
    const rect = this.svg.getBoundingClientRect();
    const mouseX = clientX !== undefined ? clientX - rect.left : rect.width / 2;
    const mouseY = clientY !== undefined ? clientY - rect.top : rect.height / 2;

    const newScale = Math.min(Math.max(this.scale * factor, 0.4), 2.5);

    this.translateX = mouseX - (mouseX - this.translateX) * (newScale / this.scale);
    this.translateY = mouseY - (mouseY - this.translateY) * (newScale / this.scale);
    this.scale = newScale;

    this.updateTransform();
  }

  focusOn(targetId, targetZoom = 1.2) {
    // Check if target needs expanding container first
    if (["fw1-a", "fw2-a", "untrust-a", "trust-a", "nlb-a"].includes(targetId)) {
      if (!this.securityVpcExpanded) {
        this.securityVpcExpanded = true;
        this.render();
      }
    }
    // The threat-prevention card only exists in the collapsed cluster view.
    if (targetId === "threat-prevention" && this.securityVpcExpanded) {
      this.securityVpcExpanded = false;
      this.render();
    }
    if (["untrust-b", "fw1-b", "fw2-b", "tgw-b", "dc-b"].includes(targetId)) {
      if (this.regionBCollapsed) {
        this.regionBCollapsed = false;
        this.render();
      }
    }

    const target = this.nodePositions[targetId];
    if (!target) {
      if (targetId === "global") {
        this.resetView();
      }
      return;
    }

    // The SVG is drawn with a viewBox (0 0 1860 1060) scaled to fit the
    // viewport ("meet", centred), so the transform is in SCENE units, not
    // screen pixels: the visible centre is always (930, 530). Upstream used
    // rect.width/2 (pixels), which put focused nodes well off-centre.
    this.scale = targetZoom;
    this.translateX = 930 - target.cx * this.scale;
    this.translateY = 530 - target.cy * this.scale;
    this.updateTransform();

    this.highlightNode(targetId);
  }

  resetView() {
    this.scale = 0.88;
    this.translateX = 40;
    this.translateY = 20;
    this.updateTransform();
    this.clearHighlights();
  }

  highlightNode(nodeId) {
    this.clearHighlights();
    const node = this.svg.querySelector(`#node-${nodeId}`);
    if (node) {
      node.classList.add("highlighted");
      this.selectedNodeId = nodeId;
    }
  }

  clearHighlights() {
    this.svg.querySelectorAll(".arch-node").forEach(n => {
      n.classList.remove("highlighted", "selected");
    });
    this.selectedNodeId = null;
  }

  toggleSecurityVpc() {
    this.securityVpcExpanded = !this.securityVpcExpanded;
    this.render();
  }

  toggleRegionB() {
    this.regionBCollapsed = !this.regionBCollapsed;
    this.render();
  }

  toggleViewMode(mode) {
    this.viewMode = mode;
    if (mode === "deepdive") {
      this.securityVpcExpanded = true;
      this.regionBCollapsed = false;
    } else {
      this.securityVpcExpanded = false;
      this.regionBCollapsed = true;
    }
    this.render();
  }

  clearLayers() {
    const ids = ["links-layer", "regions-layer", "vpcs-layer", "subnets-layer", "nodes-layer", "animation-layer"];
    ids.forEach(id => {
      const el = this.svg.querySelector(`#${id}`);
      if (el) el.innerHTML = "";
    });
  }
}
