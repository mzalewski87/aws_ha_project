/**
 * SVG Architecture Diagram Engine
 * Enterprise-grade hierarchical diagram with collapsible VPCs/regions,
 * overview/deep-dive presets, and bilingual (PL / EN) localization.
 */

const I18N_DIAGRAM = {
  pl: {
    edge_tier: "WARSTWA BRZEGOWA I WEJŚCIOWA (GLOBAL EDGE INGRESS)",
    regionA_title: "REGION A (Podstawowy) — eu-central-1 (Frankfurt)",
    regionA_sub: "Centralna Panorama | Active/Passive VM-Series HA | Transit Gateway Hub | Spoke VPCs",
    secVpc_title: "Security VPC — VM-Series HA Hub (10.10.0.0/16)",
    btn_expand_subnets: "🔍 Rozwiń Podsieci",
    btn_collapse_cluster: "▲ Zwiń do Klastra",
    cluster_title: "VM-Series Active/Passive HA Cluster",
    cluster_sub: "Pływający EIP (.100) ➔ Loopback.1 | eth0..eth3 | Appliance Mode TGW",
    cluster_desc: "Wtyczka PAN-OS AWS HA Plugin automatycznie przepisuje EIP oraz trasę 0.0.0.0/0 w razie awarii",
    untrust_subnet: "Untrust Subnet (Public IGW + Floating EIP)",
    trust_subnet: "Trust Subnet (TGW-Facing Dataplane)",
    secVpc_expanded_title: "Security VPC (10.10.0.0/16) — Rozwinięte Podsieci i Interfejsy ENI",
    regionB_dr_tag: "DISASTER RECOVERY STANDBY",
    regionB_title: "REGION B — eu-west-1 (Dublin)",
    regionB_sub: "Lustrzany stack bezpieczeństwa (10.20/16)",
    regionB_h1: "✓ Standby Anycast Global Accelerator",
    regionB_h1_sub: "~30s przełączenie portalu GP przy awarii A",
    regionB_h2: "✓ Replikacja AD Multi-Master",
    regionB_h2_sub: "Kontroler 10.23.0.10 gotowy w 3 sekundy",
    regionB_h3: "✓ Centralny Zarząd z Panoramy A",
    regionB_h3_sub: "Brak konieczności instalowania drugiej Panoramy",
    btn_expand_regb: "📂 Rozwiń Pełny Stack Regionu B",
    btn_collapse_regb: "✖ Zwiń B",
    regionB_exp_title: "REGION B (Zapasowy / DR) — eu-west-1 (Dublin)",
    regionB_exp_sub: "Lustrzany stack (10.20/16) | Anycast Standby | Zreplikowany DC",
    secVpcB_title: "Security VPC B (10.20.0.0/16) — Standby Klaster HA",
    regionB_highlights_title: "Architektura Odporności Regionu B",
    regionB_hl1: "✓ Identyczny moduł Terraform (region_stack)",
    regionB_hl2: "✓ Zarządzany z Panoramy A przez TGW Peering",
    regionB_hl3: "✓ Replikacja AD po prywatnym szkielecie AWS",
    regionB_hl4: "✓ Pełna izolacja od ewentualnej awarii Regionu A"
  },
  en: {
    edge_tier: "GLOBAL EDGE & INGRESS TIER",
    regionA_title: "REGION A (Primary) — eu-central-1 (Frankfurt)",
    regionA_sub: "Central Panorama | Active/Passive VM-Series HA | Transit Gateway Hub | Spoke VPCs",
    secVpc_title: "Security VPC — VM-Series HA Hub (10.10.0.0/16)",
    btn_expand_subnets: "🔍 Expand Subnets",
    btn_collapse_cluster: "▲ Collapse to Cluster",
    cluster_title: "VM-Series Active/Passive HA Cluster",
    cluster_sub: "Floating EIP (.100) ➔ Loopback.1 | eth0..eth3 | Appliance Mode TGW",
    cluster_desc: "PAN-OS AWS HA Plugin automatically remaps EIP and 0.0.0.0/0 route on failover",
    untrust_subnet: "Untrust Subnet (Public IGW + Floating EIP)",
    trust_subnet: "Trust Subnet (TGW-Facing Dataplane)",
    secVpc_expanded_title: "Security VPC (10.10.0.0/16) — Expanded Subnets & ENI Datapaths",
    regionB_dr_tag: "DISASTER RECOVERY STANDBY",
    regionB_title: "REGION B — eu-west-1 (Dublin)",
    regionB_sub: "Mirrored security stack (10.20/16)",
    regionB_h1: "✓ Standby Anycast Global Accelerator",
    regionB_h1_sub: "~30s GP portal failover upon Region A loss",
    regionB_h2: "✓ AD Multi-Master Replication",
    regionB_h2_sub: "Replica DC 10.23.0.10 ready in 3 seconds",
    regionB_h3: "✓ Governed from Region A Panorama",
    regionB_h3_sub: "No secondary Panorama instance required",
    btn_expand_regb: "📂 Expand Full Region B Stack",
    btn_collapse_regb: "✖ Collapse B",
    regionB_exp_title: "REGION B (Secondary / DR) — eu-west-1 (Dublin)",
    regionB_exp_sub: "Mirrored stack (10.20/16) | Anycast Standby | Replicated DC",
    secVpcB_title: "Security VPC B (10.20.0.0/16) — Standby HA Cluster",
    regionB_highlights_title: "Region B Resilience Highlights",
    regionB_hl1: "✓ Identical Terraform module (region_stack)",
    regionB_hl2: "✓ Centrally governed by the Region A Panorama over TGW peering",
    regionB_hl3: "✓ AD replication over AWS private backbone",
    regionB_hl4: "✓ Complete isolation from Region A failures"
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

  render() {
    this.clearLayers();
    this.nodePositions = {};

    // 1. Render Global Plane (Ingress / Edge Tier)
    this.renderGlobalPlane();

    // 2. Render Region A (Frankfurt - Primary)
    this.renderRegionA();

    // 3. Render Region B (Dublin - DR Standby)
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

    // Background tier header
    html += `
      <g transform="translate(60, 16)">
        <text fill="#64748B" font-size="11" font-weight="700" letter-spacing="0.08em">${this.t("edge_tier")}</text>
      </g>
    `;

    // GP Client
    html += this.createNodeHtml({
      id: "gp-client",
      x: 70,
      y: 36,
      w: 220,
      h: 68,
      title: "GlobalProtect Clients",
      sub: isEn ? "Remote Users (SSL / IPSec)" : "Użytkownicy zdalni (SSL / IPSec)",
      icon: "user-client",
      badge: isEn ? "External" : "Klient VPN",
      badgeClass: "passive-bg"
    });

    // AWS Global Accelerator
    html += this.createNodeHtml({
      id: "global-accelerator",
      x: 320,
      y: 36,
      w: 300,
      h: 68,
      title: "AWS Global Accelerator",
      sub: "Anycast IPs | TCP 443 / UDP 4501",
      icon: "aws-global-accelerator",
      badge: "~30s Failover",
      badgeClass: "active-bg"
    });

    // AWS CloudFront
    html += this.createNodeHtml({
      id: "cloudfront",
      x: 650,
      y: 36,
      w: 270,
      h: 68,
      title: "AWS CloudFront CDN",
      sub: isEn ? "Edge Caching & Shield DDoS" : "Buforowanie & Shield DDoS",
      icon: "aws-cloudfront",
      badge: "Edge Ingress",
      badgeClass: "active-bg"
    });

    // Web Users
    html += this.createNodeHtml({
      id: "web-user",
      x: 950,
      y: 36,
      w: 200,
      h: 68,
      title: "Internet Web Users",
      sub: isEn ? "Public HTTPS App Traffic" : "Publiczny ruch HTTPS",
      icon: "user-client",
      badge: isEn ? "Public Client" : "Użytkownik WWW",
      badgeClass: "passive-bg"
    });

    nodesLayer.insertAdjacentHTML("beforeend", html);
  }

  renderRegionA() {
    const regionsLayer = this.svg.querySelector("#regions-layer");
    const vpcsLayer = this.svg.querySelector("#vpcs-layer");
    const nodesLayer = this.svg.querySelector("#nodes-layer");

    const isEn = this.lang === "en";
    const isSecExpanded = this.securityVpcExpanded;
    const regHeight = isSecExpanded ? 880 : 700;

    // Region Box
    regionsLayer.insertAdjacentHTML("beforeend", `
      <rect id="region-a" class="region-box region-a" x="60" y="130" width="860" height="${regHeight}" />
      <g transform="translate(84, 160)">
        <text class="region-label">${this.t("regionA_title")}</text>
        <text class="region-sublabel" y="18">${this.t("regionA_sub")}</text>
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

      // Unified HA Cluster Card
      nodesLayer.insertAdjacentHTML("beforeend", `
        <g id="node-fw-pair-a" class="arch-node" transform="translate(104, 235)" onclick="window.app.selectComponent('fw-pair-a')">
          <rect class="cluster-overview-card" width="722" height="92" rx="10" />
          <g transform="translate(16, 16)">
            <g class="node-icon">${ICONS["panw-vmseries"]}</g>
            <text fill="#FFFFFF" font-size="14" font-weight="700" x="48" y="18">${this.t("cluster_title")}</text>
            <text fill="#94A3B8" font-size="11" font-family="var(--font-mono)" x="48" y="36">${this.t("cluster_sub")}</text>
            <text fill="#64748B" font-size="10.5" x="48" y="54">${this.t("cluster_desc")}</text>
          </g>
          <g transform="translate(560, 16)">
            <rect width="70" height="20" rx="4" fill="rgba(16,185,129,0.2)" stroke="#10B981" />
            <text x="35" y="14" fill="#10B981" font-size="9.5" font-weight="700" text-anchor="middle">FW1: ACTIVE</text>
          </g>
          <g transform="translate(636, 16)">
            <rect width="72" height="20" rx="4" fill="rgba(100,116,139,0.2)" stroke="#64748B" />
            <text x="36" y="14" fill="#94A3B8" font-size="9.5" font-weight="700" text-anchor="middle">FW2: PASSIVE</text>
          </g>
        </g>
      `);

      // Map internal nodes to the cluster center for flow animations
      this.nodePositions["fw-pair-a"] = { x: 104, y: 235, w: 722, h: 92, cx: 465, cy: 281 };
      this.nodePositions["untrust-a"] = { cx: 260, cy: 281, x: 110, y: 240, w: 300, h: 80 };
      this.nodePositions["nlb-a"] = { cx: 650, cy: 281, x: 500, y: 240, w: 300, h: 80 };
      this.nodePositions["fw1-a"] = { cx: 260, cy: 281, x: 110, y: 240, w: 300, h: 80 };
      this.nodePositions["fw2-a"] = { cx: 650, cy: 281, x: 500, y: 240, w: 300, h: 80 };
      this.nodePositions["trust-a"] = { cx: 465, cy: 320, x: 104, y: 280, w: 722, h: 40 };

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
        <text class="subnet-cidr" x="730" y="253">10.10.10.0/24</text>

        <!-- Trust Subnet -->
        <rect class="subnet-box" x="100" y="464" width="730" height="80" />
        <text class="subnet-label" x="114" y="482">${this.t("trust_subnet")}</text>
        <text class="subnet-cidr" x="730" y="482">10.10.20.0/24</text>
      `);

      // Untrust Floating EIP
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "untrust-a",
        x: 114,
        y: 265,
        w: 340,
        h: 42,
        title: "Untrust Floating EIP (.100)",
        sub: isEn ? "loopback.1 | GP Portal & GW" : "loopback.1 | Portal & Brama GP",
        icon: "panw-globalprotect",
        badge: "Elastic IP",
        badgeClass: "active-bg"
      }));

      // App NLB
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "nlb-a",
        x: 476,
        y: 265,
        w: 340,
        h: 42,
        title: "App NLB (Network Load Balancer)",
        sub: isEn ? "Target: Untrust .100:80 ➔ DNAT" : "Cel: Untrust .100:80 ➔ DNAT",
        icon: "aws-nlb",
        badge: "Dual-AZ",
        badgeClass: "active-bg"
      }));

      // FW1 Active Node
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "fw1-a",
        x: 114,
        y: 330,
        w: 340,
        h: 114,
        title: "VM-Series FW1 (Active)",
        sub: isEn ? "Priority: 100 | EIP Owner | m5.xlarge" : "Priorytet: 100 | Właściciel EIP | m5.xlarge",
        icon: "panw-vmseries",
        badge: "ACTIVE",
        badgeClass: "active-bg",
        customCardClass: "fw-active",
        detailsSnippet: "eth0(mgmt) • eth1(ha2) • eth2(trust) • eth3(untrust)"
      }));

      // FW2 Passive Node
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "fw2-a",
        x: 476,
        y: 330,
        w: 340,
        h: 114,
        title: "VM-Series FW2 (Passive)",
        sub: isEn ? "Priority: 110 | Preemption: NO | Standby" : "Priorytet: 110 | Preemption: NIE | Standby",
        icon: "panw-vmseries",
        badge: "PASSIVE",
        badgeClass: "passive-bg",
        customCardClass: "fw-passive",
        detailsSnippet: "eth0(mgmt) • eth1(ha2) • eth2(trust) • eth3(untrust)"
      }));

      // Trust Interface Box
      nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
        id: "trust-a",
        x: 114,
        y: 494,
        w: 702,
        h: 42,
        title: isEn ? "Trust ENI & Inspection Gateway (ethernet1/2)" : "Trust ENI & Brama Inspekcyjna (ethernet1/2)",
        sub: isEn ? "Default Route: 0.0.0.0/0 ➔ Trust ENI | AWS HA Plugin ReplaceRoute" : "Trasa 0.0.0.0/0 ➔ Trust ENI | Wtyczka HA ReplaceRoute",
        icon: "aws-transit-gateway",
        badge: "TGW Facing",
        badgeClass: "active-bg"
      }));

      this.nodePositions["fw-pair-a"] = { x: 114, y: 330, w: 702, h: 114, cx: 465, cy: 387 };
    }

    // ==========================================
    // 2. TRANSIT GATEWAY A
    // ==========================================
    const tgwY = isSecExpanded ? 580 : 375;
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "tgw-a",
      x: 230,
      y: tgwY,
      w: 470,
      h: 66,
      title: "Transit Gateway Region A (ASN 64512)",
      sub: isEn ? "Appliance Mode: ENABLED (Cross-AZ Symmetry Hub)" : "Appliance Mode: WŁĄCZONY (Symetria stref AZ)",
      icon: "aws-transit-gateway",
      badge: isEn ? "Central Hub" : "Główny Hub",
      badgeClass: "active-bg"
    }));

    // ==========================================
    // 3. MANAGEMENT VPC & SPOKES
    // ==========================================
    const lowerTierY = isSecExpanded ? 680 : 475;
    const lowerTierHeight = isSecExpanded ? 320 : 205;

    // Management VPC
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box mgmt-vpc" x="84" y="${lowerTierY}" width="370" height="${lowerTierHeight}" />
      <text class="vpc-title" x="104" y="${lowerTierY + 22}">Management VPC</text>
      <text class="vpc-cidr" text-anchor="end" x="440" y="${lowerTierY + 22}">10.11.0.0/16</text>
    `);

    // Panorama
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "panorama",
      x: 104,
      y: lowerTierY + 36,
      w: 330,
      h: 70,
      title: "Panorama Central Management",
      sub: isEn ? "10.11.0.10 | m5.4xlarge | 2TB Log EBS" : "10.11.0.10 | m5.4xlarge | 2TB EBS na Logi",
      icon: "panw-panorama",
      badge: isEn ? "Central Mgmt" : "Zarządzanie",
      badgeClass: "active-bg"
    }));

    // SSM Jump Host
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "ssm-jumphost",
      x: 104,
      y: lowerTierY + 116,
      w: 330,
      h: 70,
      title: "SSM Jump Host (Zero-Bastion)",
      sub: isEn ? "No public ports | Port-Forwarding 44300" : "Brak publicznych portów | Tunel SSM 44300",
      icon: "aws-ssm",
      badge: "SSM Tunnel",
      badgeClass: "active-bg"
    }));

    // Spoke 1 (Apache)
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box spoke-vpc" x="474" y="${lowerTierY}" width="200" height="${lowerTierHeight}" />
      <text class="vpc-title" x="488" y="${lowerTierY + 22}">Spoke 1 (App)</text>
      <text class="vpc-cidr" text-anchor="end" x="660" y="${lowerTierY + 22}">10.12/16</text>
    `);

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "apache-a",
      x: 488,
      y: lowerTierY + 36,
      w: 172,
      h: 150,
      title: "Apache Web App",
      sub: "10.12.0.10<br/>Port 80 HTTP",
      icon: "aws-ec2",
      badge: "EC2 App",
      badgeClass: "active-bg"
    }));

    // Spoke 2 (Active Directory)
    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box spoke-vpc" x="694" y="${lowerTierY}" width="200" height="${lowerTierHeight}" />
      <text class="vpc-title" x="708" y="${lowerTierY + 22}">Spoke 2 (AD DS)</text>
      <text class="vpc-cidr" text-anchor="end" x="880" y="${lowerTierY + 22}">10.13/16</text>
    `);

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "dc-a",
      x: 708,
      y: lowerTierY + 36,
      w: 172,
      h: 150,
      title: isEn ? "Windows DC (Primary)" : "Windows DC (Podstawowy)",
      sub: "panw.labs<br/>10.13.0.10",
      icon: "aws-directory-service",
      badge: "Forest Root",
      badgeClass: "active-bg"
    }));
  }

  renderRegionBCollapsed() {
    const regionsLayer = this.svg.querySelector("#regions-layer");
    const isSecExpanded = this.securityVpcExpanded;
    const regHeight = isSecExpanded ? 880 : 700;

    regionsLayer.insertAdjacentHTML("beforeend", `
      <g id="region-b" transform="translate(980, 130)">
        <rect class="collapsed-card" width="360" height="${regHeight}" rx="14" />
        
        <g transform="translate(24, 32)">
          <text fill="#FA582D" font-size="11" font-weight="700" letter-spacing="0.06em">${this.t("regionB_dr_tag")}</text>
          <text fill="#FFFFFF" font-size="15" font-weight="700" y="24">${this.t("regionB_title")}</text>
          <text fill="#94A3B8" font-size="11.5" y="44">${this.t("regionB_sub")}</text>
        </g>

        <!-- Highlights List -->
        <g transform="translate(24, 110)">
          <rect width="312" height="150" rx="8" fill="rgba(15,23,42,0.6)" stroke="#334155" />
          <text x="14" y="26" fill="#38BDF8" font-size="11" font-weight="700">${this.t("regionB_h1")}</text>
          <text x="14" y="44" fill="#94A3B8" font-size="10.5">${this.t("regionB_h1_sub")}</text>

          <text x="14" y="72" fill="#38BDF8" font-size="11" font-weight="700">${this.t("regionB_h2")}</text>
          <text x="14" y="90" fill="#94A3B8" font-size="10.5">${this.t("regionB_h2_sub")}</text>

          <text x="14" y="118" fill="#38BDF8" font-size="11" font-weight="700">${this.t("regionB_h3")}</text>
          <text x="14" y="136" fill="#94A3B8" font-size="10.5">${this.t("regionB_h3_sub")}</text>
        </g>

        <!-- Big Expand Action Button -->
        <g class="btn-container-toggle" transform="translate(24, 290)" onclick="window.app.toggleRegionB()">
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
    const isSecExpanded = this.securityVpcExpanded;
    const regHeight = isSecExpanded ? 880 : 700;

    // Region B Box
    regionsLayer.insertAdjacentHTML("beforeend", `
      <rect id="region-b" class="region-box region-b" x="980" y="130" width="810" height="${regHeight}" />
      <g transform="translate(924, 160)">
        <text class="region-label">${this.t("regionB_exp_title")}</text>
        <text class="region-sublabel" y="18">${this.t("regionB_exp_sub")}</text>
      </g>
      <g class="btn-container-toggle" transform="translate(1600, 144)" onclick="window.app.toggleRegionB()">
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
      x: 1024,
      y: 235,
      w: 350,
      h: 90,
      title: "Untrust Floating EIP (.100) B",
      sub: "Dublin GP Portal & GW | Anycast Standby",
      icon: "panw-globalprotect",
      badge: "Standby EIP",
      badgeClass: "active-bg"
    }));

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "fw1-b",
      x: 1394,
      y: 235,
      w: 350,
      h: 90,
      title: isEn ? "VM-Series FW Pair B" : "Para VM-Series Region B",
      sub: isEn ? "FW1 (Active) / FW2 (Passive) | Panorama in Region A" : "FW1 (Active) / FW2 (Passive) | Panorama w Regionie A",
      icon: "panw-vmseries",
      badge: "DR Ready",
      badgeClass: "active-bg"
    }));

    // TGW B
    const tgwY = isSecExpanded ? 580 : 375;
    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "tgw-b",
      x: 1150,
      y: tgwY,
      w: 470,
      h: 66,
      title: "Transit Gateway Region B (ASN 64512)",
      sub: isEn ? "Peering Accepter to Region A TGW (Appliance Mode Enabled)" : "Akceptor Peer-ingu do TGW A (Appliance Mode Włączony)",
      icon: "aws-transit-gateway",
      badge: "DR Hub",
      badgeClass: "active-bg"
    }));

    // Replica DC B
    const lowerTierY = isSecExpanded ? 680 : 475;
    const lowerTierHeight = isSecExpanded ? 320 : 205;

    vpcsLayer.insertAdjacentHTML("beforeend", `
      <rect class="vpc-box spoke-vpc" x="1004" y="${lowerTierY}" width="370" height="${lowerTierHeight}" />
      <text class="vpc-title" x="1024" y="${lowerTierY + 22}">Spoke 2 (Replica DC)</text>
      <text class="vpc-cidr" text-anchor="end" x="1360" y="${lowerTierY + 22}">10.23/16</text>
    `);

    nodesLayer.insertAdjacentHTML("beforeend", this.createNodeHtml({
      id: "dc-b",
      x: 1024,
      y: lowerTierY + 36,
      w: 330,
      h: 150,
      title: isEn ? "Windows DC Replica" : "Windows DC (Replika)",
      sub: "panw.labs (Multi-Master)<br/>10.23.0.10",
      icon: "aws-directory-service",
      badge: "AD Replication",
      badgeClass: "active-bg"
    }));

    // Info panel in Region B
    nodesLayer.insertAdjacentHTML("beforeend", `
      <g transform="translate(1394, ${lowerTierY})">
        <rect width="372" height="${lowerTierHeight}" rx="10" fill="rgba(30,41,59,0.5)" stroke="#334155" />
        <text x="18" y="28" fill="#E2E8F0" font-size="12" font-weight="700">${this.t("regionB_highlights_title")}</text>
        <text x="18" y="55" fill="#94A3B8" font-size="11">${this.t("regionB_hl1")}</text>
        <text x="18" y="80" fill="#94A3B8" font-size="11">${this.t("regionB_hl2")}</text>
        <text x="18" y="105" fill="#94A3B8" font-size="11">${this.t("regionB_hl3")}</text>
        <text x="18" y="130" fill="#94A3B8" font-size="11">${this.t("regionB_hl4")}</text>
      </g>
    `);
  }

  renderInterconnects() {
    const linksLayer = this.svg.querySelector("#links-layer");
    let html = "";

    // 1. Client ➔ Global Accelerator
    html += this.createLinkPath("gp-client", "global-accelerator", { stroke: "#38BDF8", dashed: true });

    // 2. GA ➔ Untrust A / Cluster A (Primary)
    html += this.createLinkPath("global-accelerator", "untrust-a", { stroke: "#00F0FF", marker: "arrow-cyan" });

    // 3. GA ➔ Untrust B (Anycast Standby)
    html += this.createLinkPath("global-accelerator", "untrust-b", { stroke: "#00F0FF", dashed: true, marker: "arrow-cyan" });

    // 4. Web User ➔ CloudFront ➔ NLB A
    html += this.createLinkPath("web-user", "cloudfront", { stroke: "#FA582D", marker: "arrow-orange" });
    html += this.createLinkPath("cloudfront", "nlb-a", { stroke: "#FA582D", marker: "arrow-orange" });

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
    html += this.createLinkPath("tgw-a", "panorama", { stroke: "#38BDF8" });
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

    const titleText = esc(cfg.title);
    const badgeText = esc(cfg.badge);
    // Upstream encodes multi-line subtitles with <br/>, which SVG does not
    // honour — the extra lines silently vanished. Split and emit real tspans.
    const subLines = esc(cfg.sub).split(/<br\s*\/?>/i).filter(Boolean);

    const badgeFont = 8.5;
    const badgeW = badgeText ? Math.max(46, Math.round(badgeText.length * badgeFont * 0.62) + 16) : 0;

    // Park the badge on a bottom row whenever it would squeeze the title, and
    // the card is tall enough to host a second row (>=60px). This is what saves
    // the narrow cards: on a 200px card a 13-char badge eats 85px of width, so
    // inline there is no room for the title at any legible size, while stacked
    // the title gets the full 136px and renders at full 11px.
    const stackBadge = Boolean(badgeText) && cfg.h >= 60 &&
      titleText.length * 11 * CH_TITLE > cfg.w - 54 - badgeW - 18;

    const titleRoom = (stackBadge ? cfg.w - 64 : cfg.w - 54 - (badgeW ? badgeW + 18 : 12));
    const subRoom   = cfg.w - 54 - 12;

    const fit = (text, room, max, min, ratio) => {
      if (!text) return { size: max, text: "" };
      let size = max;
      while (size > min && text.length * size * ratio > room) size -= 0.5;
      if (text.length * size * ratio > room) {
        const keep = Math.max(3, Math.floor(room / (size * ratio)) - 1);
        return { size, text: text.slice(0, keep).trimEnd() + "\u2026" };
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
         <text fill="#FFFFFF" font-size="${badgeFont}" font-weight="700" x="${12 + badgeW / 2}" y="${cfg.h - 13}" text-anchor="middle">${badgeText}</text>`
      : `<rect class="node-badge ${cfg.badgeClass || ''}" x="${cfg.w - badgeW - 10}" y="8" width="${badgeW}" height="18" rx="4" />
         <text fill="#FFFFFF" font-size="${badgeFont}" font-weight="700" x="${cfg.w - badgeW / 2 - 10}" y="20" text-anchor="middle">${badgeText}</text>`;

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

    return `
      <line ${id} class="arch-link ${extraClass}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}"
        stroke="${stroke}" stroke-width="${width}" ${dash} />
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

    const rect = this.svg.getBoundingClientRect();
    const centerX = rect.width / 2;
    const centerY = rect.height / 2;

    this.scale = targetZoom;
    this.translateX = centerX - target.cx * this.scale;
    this.translateY = centerY - target.cy * this.scale;
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
