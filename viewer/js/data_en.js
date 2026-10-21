/**
 * AWS VM-Series HA & Multi-Region GlobalProtect Architecture Data Model (English)
 * Based on https://github.com/mzalewski87/aws_ha_project
 *
 * Two management paths from one codebase (ADR D11):
 *   A = self-hosted Panorama (EC2)      B = Strata Cloud Manager (SaaS)
 * Entries tagged mgmtPath: "A" | "B" switch the diagram to that path.
 */

const ARCHITECTURE_DATA_EN = {
  projectInfo: {
    title: "AWS VM-Series HA — Multi-Region GlobalProtect",
    subtitle: "Enterprise Resilient Architecture Presentation",
    repoUrl: "https://github.com/mzalewski87/aws_ha_project",
    author: "Mikołaj Zalewski",
    version: "v2.0",
    panosVersion: "12.2.4 (path B minimum) / 11.1.15 (path A default)",
    panoramaVersion: "11.1.15 (path A only)",
    keyConcepts: [
      "Active/Passive VM-Series HA with the PAN-OS AWS HA plugin (secondary-IP mode)",
      "Multi-region resilience via AWS Global Accelerator (nearest healthy region)",
      "Native GlobalProtect gateway failover (no external LB)",
      "Transit Gateway with Appliance Mode (cross-AZ flow symmetry)",
      "Two management paths: Panorama (A) or Strata Cloud Manager (B)",
      "Resilient Active Directory (replica DC in Region B) + two-tier AD CS PKI"
    ]
  },

  // Diagram ids without a drawer entry of their own open this one instead.
  componentAliases: {
    "fw1-a": "fw-pair-a",
    "fw2-a": "fw-pair-a",
    "fw1-b": "fw-pair-b",
    "untrust-b": "globalprotect-service",
    "apache-a": "spoke1-app",
    "dc-a": "spoke2-dc"
  },

  // Presentation slides for guided walkthrough (English)
  presentationSlides: [
    {
      id: "intro",
      title: "1. Project Objective & Business Rationale",
      targetFocus: "global",
      zoomLevel: 1.0,
      content: `
        <h4>Core Business Objective ("North Star")</h4>
        <p>Deliver uninterrupted enterprise VPN access (<strong>GlobalProtect Portal + Gateway</strong>) for a remote workforce, plus central traffic inspection, that <strong>survives individual firewall failures, Availability Zone outages and the loss of a whole AWS region</strong>.</p>
        <div class="callout-box">
          <strong>Why is this different?</strong> No DNS failover (ISP TTL caching). Clients keep the same two anycast IPs; Global Accelerator marks a region down after <strong>one</strong> failed 10 s health check and moves its clients to the other region. Inside a region the HA pair switches over in ~1–8 s.
        </div>
      `
    },
    {
      id: "mgmt_paths",
      title: "2. Two Management Paths: Panorama (A) or Strata Cloud Manager (B) — ADR D11",
      targetFocus: "global",
      zoomLevel: 1.0,
      mgmtPath: "B",
      content: `
        <p>One codebase, selected with <code>management_mode</code>. Everything that is not management (VPCs, TGW, HA pair, GP, DC/PKI, Guacamole) is shared. Use the <strong>MANAGEMENT PATH</strong> switch on the diagram (top right) or in the left panel to compare.</p>
        <table class="slide-table">
          <tr><th></th><th>Path A — Panorama</th><th>Path B — Strata Cloud Manager</th></tr>
          <tr><td>Manager</td><td>Panorama EC2 + 2 TB log EBS</td><td>SCM tenant (SaaS), no EC2</td></tr>
          <tr><td>Bootstrap</td><td><code>panorama-server=&lt;ip&gt;</code> + vm-auth-key</td><td><code>panorama-server=cloud</code> + registration PIN</td></tr>
          <tr><td>Config</td><td>template stack + device group</td><td>one folder for both regions; per-device variables</td></tr>
          <tr><td>HA config</td><td><code>configure-ha.sh</code> (SSH)</td><td>from SCM (<code>scm-ha.sh</code>, REST)</td></tr>
          <tr><td>Routing</td><td>legacy virtual router</td><td>Advanced Routing Engine logical router</td></tr>
          <tr><td>PAN-OS</td><td>pinned, Panorama ≥ FW (default 11.1.15)</td><td>12.2.4 minimum (image 12.2.3 ➔ in-place upgrade)</td></tr>
        </table>
      `
    },
    {
      id: "ha_choice",
      title: "3. HA Model: Active/Passive vs GWLB (ADR D1)",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.35,
      content: `
        <h4>Architectural Decision Record (ADR D1)</h4>
        <p>Each region deploys an <strong>Active/Passive VM-Series pair</strong> with dedicated HA1 (control/heartbeat) and HA2 (state synchronization) links; failover on the AWS side is driven by the PAN-OS AWS HA plugin.</p>
        <p><strong>Why NOT AWS Gateway Load Balancer (GWLB)?</strong></p>
        <ul>
          <li>GWLB is a transparent "bump-in-the-wire" mechanism using GENEVE encapsulation and has no client-addressable public IP per firewall.</li>
          <li>GlobalProtect terminates client VPN traffic on a public IP, which needs a deterministic, stable ingress point.</li>
          <li>Active/Passive with a floating secondary IP (carrying the EIP) keeps one stable public entry per region.</li>
        </ul>
      `
    },
    {
      id: "eni_quirks",
      title: "4. ENI Interface Ordering & AWS Quirks",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.5,
      content: `
        <h4>PAN-OS Platform Requirements on AWS EC2</h4>
        <p>Strict interface ordering (device_index) is mandatory for proper datapath and state sync:</p>
        <ul>
          <li><code>device_index=0</code> (eth0) ➔ <strong>Management (HA1)</strong>: control plane, ICMP echo, and TCP 28769/28260.</li>
          <li><code>device_index=1</code> (eth1) ➔ <strong>HA2 (Data Link)</strong>: AWS requirement – firewall port <code>ethernet1/1</code> MUST be HA2.</li>
          <li><code>device_index=2</code> (eth2) ➔ <strong>Trust (ethernet1/2)</strong>: Transit Gateway dataplane (source/dest check off), floating secondary <code>10.10.20.100</code>.</li>
          <li><code>device_index=3</code> (eth3) ➔ <strong>Untrust (ethernet1/3)</strong>: public traffic, floating secondary <code>10.10.10.100</code> (carries the EIP; GP binds it as <strong>loopback.1</strong>).</li>
        </ul>
        <p>The floating <code>.100</code> must be a <strong>secondary</strong> address — the module passes an ordered IP list so it never becomes the primary.</p>
      `
    },
    {
      id: "ha_failover",
      title: "5. HA Failover: What Actually Moves (measured)",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.3,
      content: `
        <h4>AWS HA plugin, secondary-IP mode (PAN-OS 12.2.4, plugin 6.2.1)</h4>
        <ul>
          <li>The unit that becomes active calls <code>AssignPrivateIpAddresses</code>: <strong>untrust .100</strong> (the EIP stays associated with it, so it follows) and <strong>trust .100</strong> move to its ENIs.</li>
          <li>It calls <code>ReplaceRoute</code> on <strong>both TGW-attachment route tables</strong>: <code>0.0.0.0/0</code> ➔ its own trust ENI.</li>
          <li>The plugin only rewrites routes that point at ENIs it moves IPs from — that is why the trust ENI carries a floating IP too. Without it the EIP moved but east-west/spoke traffic was black-holed.</li>
        </ul>
        <div class="callout-box"><strong>Measured live:</strong> takeover 0.7–7.7 s; GP portal unreachable ~5 s per switchover; CloudTrail shows the API calls ~6 s after the suspend. Preemption stays off.</div>
      `
    },
    {
      id: "tgw_appliance",
      title: "6. Transit Gateway & Appliance Mode (ADR D5)",
      targetFocus: "tgw-a",
      zoomLevel: 1.4,
      content: `
        <h4>Central Hub & Stateful Flow Symmetry</h4>
        <p>All VPCs in the region (Security, Mgmt, Spoke 1, Spoke 2) attach to the AWS Transit Gateway.</p>
        <div class="callout-box warning">
          <strong>Mandatory Flag:</strong> <code>appliance_mode_support = enable</code> on the Security VPC Attachment.
        </div>
        <p>Without Appliance Mode, return traffic in a Multi-AZ architecture can route back through a firewall in a different AZ, and stateful inspection drops the session. Appliance Mode forces bidirectional symmetry across AZs.</p>
      `
    },
    {
      id: "mgmt_panorama",
      title: "7. Path A: Panorama & Zero-Bastion (ADR D6, D8)",
      targetFocus: "panorama",
      zoomLevel: 1.35,
      mgmtPath: "A",
      content: `
        <h4>Single Panorama Instance Across All Regions</h4>
        <p>One Panorama instance (<code>m5.4xlarge</code>, 2 TB dedicated logging EBS) in Region A governs all firewalls in both regions over private TGW peering. Template stack <code>AWS-Transit-Stack</code>, device group <code>AWS-Transit-DG</code>; the <code>panos</code> provider runs in its own workspace.</p>
        <h4>Zero-Bastion Security Posture</h4>
        <p>No public SSH or HTTPS management ports. Terraform, XML API and GUI go through <strong>AWS SSM Session Manager port forwarding</strong> via an internal SSM jump host.</p>
      `
    },
    {
      id: "mgmt_scm",
      title: "8. Path B: Strata Cloud Manager in Practice",
      targetFocus: "scm",
      zoomLevel: 1.25,
      mgmtPath: "B",
      content: `
        <h4>No Panorama EC2 — the firewalls register to SCM themselves</h4>
        <ul>
          <li>init-cfg: <code>panorama-server=cloud</code> + registration PIN (device certificate) + <code>advance-routing:enable</code>.</li>
          <li><strong>One SCM folder</strong> (<code>phase2-scm-config/</code>, <code>scm</code> provider) holds <strong>both regions' pairs</strong>; region values (floating IP, next hops, gateway) are <strong>per-device variables</strong>.</li>
          <li><strong>HA is configured from SCM</strong> (REST, <code>scm-ha.sh</code>); routing is an <strong>ARE logical router</strong> — SCM's bootstrap push rejects interfaces outside one.</li>
          <li><strong>PAN-OS 12.2.4 minimum</strong>: the newest Marketplace BYOL image is 12.2.3, so <code>scm-upgrade.sh</code> upgrades in place through SCM.</li>
          <li>GP portal/gateway have no SCM API object: built device-locally on <strong>each</strong> unit (<code>scm-gp-local.sh</code>).</li>
        </ul>
      `
    },
    {
      id: "multi_region_ga",
      title: "9. Multi-Region Resilience: Global Accelerator (ADR D3)",
      targetFocus: "global-accelerator",
      zoomLevel: 1.25,
      content: `
        <h4>Nearest healthy region — not a split, not a priority</h4>
        <ul>
          <li>Two static anycast IPs front the portal (TCP 443, UDP 4501, TCP 80 ➔ redirect ALB).</li>
          <li>Both endpoint groups run at a <strong>100% traffic dial</strong>: each client goes to its <strong>nearest healthy</strong> region, measured from its GA edge. Clients in Poland ➔ eu-central-1 (Region A); clients nearer Ireland ➔ eu-west-1.</li>
          <li>Health check TCP 443 every <strong>10 s</strong> (the shortest GA allows), <strong>threshold 1</strong>: one failed check moves that region's clients to the other region (~10 s detection).</li>
        </ul>
        <div class="callout-box">With GA's default threshold of 3 a region outage left the portal unreachable for <strong>73 s</strong> in the panel's test — hence threshold 1. The price: one lost health check also moves traffic.</div>
      `
    },
    {
      id: "gp_native_failover",
      title: "10. Native GlobalProtect Gateway Selection (ADR D4)",
      targetFocus: "global",
      zoomLevel: 1.1,
      content: `
        <h4>No External Load Balancers in Front of VPN Gateways</h4>
        <p>Every portal (all four units) issues the same external gateway list:</p>
        <ul>
          <li><code>gw-a.&lt;zone&gt;</code> — Region A firewall EIP, client pool 10.10.200.0/24</li>
          <li><code>gw-b.&lt;zone&gt;</code> — Region B firewall EIP, client pool 10.20.200.0/24</li>
        </ul>
        <p>The agent measures SSL response time, connects to the best available gateway and fails over natively when one becomes unreachable (in the path B lab both carry priority 1). One Let's Encrypt wildcard covers portal and gateways.</p>
      `
    },
    {
      id: "ad_replication",
      title: "11. Identity: Replicated AD DS + Two-Tier AD CS PKI",
      targetFocus: "dc-a",
      zoomLevel: 1.2,
      content: `
        <h4>Authentication that survives a regional disaster</h4>
        <ul>
          <li>Primary DC <code>10.13.0.10</code> (<code>panw.labs</code>) in Region A, <strong>replica DC</strong> <code>10.23.0.10</code> in Region B; AD replication over TGW peering (<code>repadmin /replsummary</code>: 0 failures both ways).</li>
          <li>LDAP profiles list both DCs; gw-b clients get the replica as primary DNS, gw-a clients the primary DC.</li>
          <li><strong>AD CS two-tier PKI</strong>: standalone root CA (<code>10.13.0.20</code>) + enterprise issuing CA (<code>10.13.0.21</code>), machine-certificate autoenrolment for GP pre-logon.</li>
        </ul>
      `
    },
    {
      id: "app_path",
      title: "12. Test Website: CloudFront + WAF ➔ NLB ➔ Firewall ➔ Apache",
      targetFocus: "cloudfront",
      zoomLevel: 1.3,
      content: `
        <h4>https://website.&lt;zone&gt; — still inspected by the firewalls</h4>
        <ol>
          <li><strong>CloudFront</strong> terminates TLS (ACM certificate in us-east-1, auto-renewing) behind a <strong>CLOUDFRONT-scope WAF</strong>.</li>
          <li>Origin is the regional <strong>app NLB</strong>; its security group admits <strong>only CloudFront's origin-facing prefix list</strong>, so nobody can go around CloudFront and its WAF.</li>
          <li>The NLB targets the floating VIP <code>10.10.10.100:80</code> on the active firewall.</li>
          <li>PAN-OS <strong>DNATs</strong> to Apache <code>10.12.0.10</code> and SNATs to its trust IP so the reply comes back through it.</li>
        </ol>
      `
    },
    {
      id: "panel_waf",
      title: "13. Admin/Test Panel, AWS WAF & Guacamole (path B lab)",
      targetFocus: "admin-panel",
      zoomLevel: 1.3,
      mgmtPath: "B",
      content: `
        <ul>
          <li><strong>Admin/test panel</strong> (<code>https://panel.&lt;zone&gt;</code>): 2 hosts in 2 AZs of the mgmt VPC behind its own ALB — outside the firewall path it reports on. AD login (<code>panel-admins</code> / <code>panel-operators</code>), live topology of both regions incl. GA health, animated policy simulation via <code>test security-policy-match</code>, failover tests (HA, hard, <strong>region outage</strong>) with measured takeover/portal-outage times; every run in DynamoDB.</li>
          <li><strong>AWS WAF</strong> on the panel ALB (REGIONAL) and on CloudFront: geo allow-list (lab: Poland), per-IP rate limit, AWS managed groups (IP reputation, anonymous IPs, known bad inputs, core rule set, SQLi). GP stays outside WAF by design.</li>
          <li><strong>Guacamole</strong> (both paths): browser-RDP via ALB + mandatory TOTP; RDP to the DC crosses the firewalls (<code>trust➔trust ms-rdp</code> rule).</li>
        </ul>
      `
    },
    {
      id: "threat",
      title: "14. Advanced IP Defense & Frontier Virtual Patching (path B)",
      targetFocus: "threat-prevention",
      zoomLevel: 1.4,
      mgmtPath: "B",
      content: `
        <ul>
          <li><strong>Advanced IP Defense</strong> (list mode, <code>ip_defense_mode = off | alert | block</code>): PANW's predefined IP lists (<code>panw-aipd-*</code>, Tor exit, bullet-proof, high-risk) at the top of the rulebase. <code>alert</code> = outbound allow + log; <code>block</code> = outbound deny + inbound deny for listed sources. Verified with <code>test security-policy-match</code>.</li>
          <li><strong>Frontier Virtual Patching</strong>: a Vulnerability Protection profile setting needing Advanced Threat Prevention Plus and <strong>PAN-OS 12.2.4+</strong> — the reason for the in-place upgrade. Pre-disclosure signatures cannot be triggered on demand.</li>
        </ul>
      `
    },
    {
      id: "summary_takeaways",
      title: "15. Client Value Proposition & Key Takeaways",
      targetFocus: "global",
      zoomLevel: 1.0,
      content: `
        <h4>Enterprise Business & Architectural Benefits</h4>
        <div class="benefits-grid">
          <div class="benefit-card">
            <div class="badge">~5 s / ~10 s</div>
            <h5>Measured Resilience</h5>
            <p>~5 s portal outage per HA switchover; a dead region is detected after one 10 s check and its clients move to the other region.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">Zero Bastion + WAF</div>
            <h5>Hardened Access</h5>
            <p>No public management ports; SSM, TOTP-gated Guacamole, WAF-fronted panel and website.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">A or B</div>
            <h5>One Codebase, Two Managers</h5>
            <p>Self-hosted Panorama or Strata Cloud Manager — same AWS architecture, fully in Terraform.</p>
          </div>
        </div>
      `
    }
  ],

  // Detailed technical components for the Drill-Down drawer (English)
  components: {
    "global-accelerator": {
      id: "global-accelerator",
      name: "AWS Global Accelerator",
      category: "AWS Edge / Routing",
      icon: "aws-global-accelerator",
      summary: "Two static anycast IPs in front of the GlobalProtect portal. Each client is sent to its NEAREST HEALTHY region; when a region fails its health check, all of its clients move to the other one.",
      details: {
        "Service Type": "AWS Global Accelerator (global; API region us-west-2)",
        "Addressing": "2 static anycast IPs; the portal FQDN gp.<zone> points at them",
        "Listeners": "TCP 443 (portal / SSL VPN), UDP 4501 (IPSec), TCP 80 (➔ HTTP➔HTTPS redirect ALB)",
        "Endpoint Groups": "Region A EIP (eu-central-1) + Region B EIP (eu-west-1), BOTH at traffic dial 100%",
        "Traffic Semantics": "Not a 50/50 split and no priority: nearest healthy region from the client's GA edge (Poland ➔ Region A)",
        "Health Checks": "TCP 443, interval 10 s (GA minimum), threshold 1 (health_check_threshold)",
        "Failover": "One failed check marks a region unhealthy (~10 s detection) and moves its clients; threshold 3 gave a measured 73 s portal outage",
        "Trade-off": "A single lost health check also moves traffic",
        "Client Affinity": "SOURCE_IP",
        "Terraform Module": "modules/global_accelerator",
        "ADR Justification": "ADR D3 – no DNS TTL / ISP caching in the failover path"
      }
    },
    "cloudfront": {
      id: "cloudfront",
      name: "AWS CloudFront — Test Website",
      category: "AWS Edge / CDN",
      icon: "aws-cloudfront",
      summary: "https://website.<zone>: CloudFront with an ACM certificate and a CLOUDFRONT-scope WAF in front of the app NLB, so the firewalls still inspect the request before Apache sees it.",
      details: {
        "Hostname": "website.<zone> (web_app_hostname)",
        "TLS": "ACM certificate in us-east-1, DNS-validated in the Route53 zone, auto-renewing",
        "WAF": "CLOUDFRONT-scope web ACL (geo allow-list, rate limit, AWS managed groups)",
        "Origin": "Regional app NLB (SG admits only CloudFront's origin-facing prefix list)",
        "Path": "CloudFront ➔ NLB ➔ firewall DNAT (.100:80) ➔ Apache 10.12.0.10",
        "DDoS Mitigation": "AWS Shield Standard (built-in L3/L4 protection)",
        "Terraform": "modules/cloudfront, web_domain.tf, waf.tf"
      }
    },
    "waf": {
      id: "waf",
      name: "AWS WAF (two web ACLs)",
      category: "AWS Edge / Web Security",
      icon: "aws-waf",
      summary: "AWS WAF in front of the two public web endpoints: the CloudFront test website and (path B) the admin panel's ALB. GlobalProtect is deliberately outside WAF.",
      details: {
        "Web ACL 1": "CLOUDFRONT scope (us-east-1) on the website distribution",
        "Web ACL 2": "REGIONAL scope (Region A) on the admin panel ALB (path B)",
        "Rule 1": "geo-allow-only: blocks every country not in waf_allowed_countries (lab: [\"PL\"]; empty = no geo rule)",
        "Rule 2": "Per-IP rate limit 1000 / 5 min (the panel's failover page polls ~150 req / 5 min per tab)",
        "Rule 3": "AWS managed groups: IP reputation, anonymous IPs (VPN/Tor/hosting), known bad inputs (Log4j…), core rule set, SQLi",
        "Visibility": "CloudWatch metrics + sampled requests per rule",
        "Outside WAF": "GlobalProtect (GA / gw EIPs: L4, clients must reach the firewalls); http://gp.<zone> test page; Guacamole ALB can take the same module",
        "Terraform": "modules/waf, waf.tf (enable_waf, default on)"
      }
    },
    "scm": {
      id: "scm",
      name: "Strata Cloud Manager (Path B)",
      category: "Palo Alto Networks Cloud Management",
      icon: "panw-scm",
      mgmtPath: "B",
      summary: "Cloud management plane replacing Panorama in path B. One SCM folder holds both regions' HA pairs; region-specific values are per-device variables. No Panorama EC2, no activation OTP.",
      details: {
        "Selected by": "management_mode = \"scm\" (ADR D11)",
        "Bootstrap (init-cfg)": "panorama-server=cloud + registration PIN; plugin-op-commands=advance-routing:enable",
        "Folder": "AWS-HA-Transit — Region A and Region B pairs (4 units)",
        "Per-device values": "scm_variable with device = overrides (floating IP, next hops, gateway)",
        "Workspace": "phase2-scm-config/ (scm provider); onboarding scm-onboard-fw.sh; push scm-push.sh (waits for every local commit)",
        "HA": "Configured from SCM (/ha-configurations, scripts/scm-ha.sh) — the provider has no HA resource",
        "Routing": "Advanced Routing Engine: scm_logical_router (one default VRF, static routes via folder variables)",
        "PAN-OS": "12.2.4 minimum; Marketplace image 12.2.3 ➔ in-place upgrade (scm-upgrade.sh, SCM upgrade rule)",
        "GlobalProtect": "No SCM API object — device-local XML on EACH unit (scm-gp-local.sh); survives SCM pushes",
        "Logging": "Strata Logging Service (tenant side)",
        "vs Path A": "Panorama EC2 + template stack/device group, vm-auth-key, configure-ha.sh over SSH"
      }
    },
    "admin-panel": {
      id: "admin-panel",
      name: "Admin / Test Panel (Path B)",
      category: "Operations Console",
      icon: "panel-dashboard",
      mgmtPath: "B",
      summary: "Web console at https://panel.<zone> on its own ALB (+ WAF), two hosts in two AZs of the mgmt VPC. It sits outside the firewall path it reports on, so it stays up through firewall and AZ failures.",
      details: {
        "Hosting": "2 × t3.small in 2 AZs (mgmt VPC 10.11/16) behind an internet-facing ALB (ACM) + REGIONAL WAF",
        "Login": "AD (NTLM bind to the DC through the firewalls) + group panel-admins (viewer) / panel-operators (operator)",
        "Sessions": "Secure, HttpOnly, SameSite=Strict cookies, 8 h absolute; CSRF tokens; per-IP and per-user login rate limit",
        "Status / Topology": "Both regions live: HA roles, EC2 state, sync, which unit holds the EIP and which the routes point at, GA endpoint health (serving (nearest) / standby / not serving)",
        "Policy Simulation": "test security-policy-match on the ACTIVE unit, animated walk of the rulebase (why earlier rules were skipped); sample addresses from predefined IP lists",
        "Failover Tests": "Check & repair sync · HA failover (~47 s) · Hard failover (~7.5 min) · Region outage (~8.5 min) · Align the pair · Recover",
        "Measured": "Takeover 0.7–7.7 s; portal unreachable ~5 s per switchover (probed every second)",
        "Run History": "DynamoDB <prefix>-panel-runs (phases, timeline, portal outages); one test at a time via a conditional DynamoDB lease",
        "Guard Rails": "Typed confirmation, recent sign-in, clean-pair precondition, timeouts, disruptive step undone if its wait fails; IAM may stop/start only the firewall instances",
        "Firewall Account": "panelro (role panel-ro): XML-API operational commands only",
        "Terraform": "modules/panel, panel.tf (enable_panel, path B only)"
      }
    },
    "guacamole": {
      id: "guacamole",
      name: "Apache Guacamole Browser-RDP (both paths)",
      category: "Remote Admin Access (ADR D12)",
      icon: "guacamole-rdp",
      summary: "Docker-based Guacamole host in the mgmt VPC behind an internet-facing ALB. RDP to the DC crosses the TGW and the firewalls, so it is inspected and logged; no RDP port is exposed.",
      details: {
        "URL": "https://rdp.<zone>/guacamole/ (ACM certificate via the Route53 custom-domain zone)",
        "Authentication": "Generated admin password in Secrets Manager; default guacadmin removed before first exposure; TOTP mandatory",
        "Fail-closed": "Bootstrap stops the container if TOTP is not enforced or guacadmin still exists",
        "Data Path": "Guacamole host ➔ TGW ➔ firewalls (rule guacamole-rdp-to-dc, trust➔trust ms-rdp, above deny-all) ➔ DC",
        "Hardening": "IMDSv2, encrypted EBS, SSM-only host access, no secrets in user-data; narrow alb_ingress_cidrs",
        "WAF": "Not attached by default; modules/waf (REGIONAL) can be added",
        "Terraform": "modules/guacamole, guacamole.tf"
      }
    },
    "pki": {
      id: "pki",
      name: "AD CS Two-Tier PKI",
      category: "Identity & Certificates",
      icon: "pki-cert",
      summary: "Standalone root CA plus an enterprise issuing CA in spoke 2, with machine-certificate autoenrolment used for GlobalProtect pre-logon.",
      details: {
        "Root CA": "10.13.0.20 — standalone, non-domain",
        "Issuing CA": "10.13.0.21 — enterprise CA, domain-joined (setup-pki.sh joins it if user-data gave up)",
        "Autoenrolment": "Machine certificates via GPO (setup-machine-autoenroll.sh) for GP pre-logon",
        "Automation": "SSM RunCommand only; live-verified on path B",
        "Known Gap": "Root CRL publish to AD fails (ERROR_DS_REFERRAL, standalone root) — root revocation checking not covered",
        "Terraform": "modules/pki (hosts), scripts/setup-pki.sh (chain)"
      }
    },
    "threat-prevention": {
      id: "threat-prevention",
      name: "Advanced IP Defense & Frontier Virtual Patching",
      category: "Palo Alto Networks Threat Prevention",
      icon: "panw-threat",
      mgmtPath: "B",
      summary: "Path B security services on the HA pairs: PANW's predefined IP-reputation lists enforced at the top of the rulebase, and Frontier Virtual Patching in the Vulnerability Protection profile.",
      details: {
        "Advanced IP Defense": "ip_defense_mode = off | alert | block (list-based variant)",
        "Lists": "Predefined EDLs panw-aipd-*, panw-torexit-ip-list, panw-bulletproof-ip-list, panw-highrisk-ip-list (inherited by every SCM folder)",
        "alert": "Outbound allow + log — a hit is visible by rule name in the traffic log",
        "block": "Outbound deny + inbound deny for listed sources",
        "Verified": "panw-aipd-c2-infra-ip-list expands to ~5500 addresses; test security-policy-match hits ipdef-outbound-alert / -block",
        "Frontier Virtual Patching": "Vulnerability Protection setting; needs Advanced Threat Prevention Plus + PAN-OS 12.2.4+",
        "Testing": "Pre-disclosure signatures cannot be triggered on demand (no PANW test method)",
        "Side effect": "Each content download is followed by a ~2 min HA-Sync job; config writes then report \"A commit is pending\""
      }
    },
    "tgw-a": {
      id: "tgw-a",
      name: "Transit Gateway Region A (Frankfurt)",
      category: "AWS Networking Hub",
      icon: "aws-transit-gateway",
      summary: "Central transit hub interconnecting all regional VPCs with mandatory Appliance Mode enabled on the Security VPC attachment.",
      details: {
        "Amazon Side ASN": "64512",
        "Appliance Mode": "ENABLE on Security VPC Attachment (Mandatory for stateful symmetry)",
        "Attachments": "Security VPC (10.10/16), Mgmt VPC (10.11/16), Spoke 1 (10.12/16), Spoke 2 (10.13/16)",
        "Route Tables": "tgw-rt-security (spoke returns) & tgw-rt-spoke (0.0.0.0/0 & east-west to Security VPC)",
        "Failover": "VPC routes 0.0.0.0/0 ➔ active unit's trust ENI are rewritten by the HA plugin (ReplaceRoute)",
        "Inter-Region Backbone": "TGW Peering Attachment to Region B (Dublin)",
        "Terraform Module": "modules/transit_gateway",
        "ADR Justification": "ADR D5 – centralized inspection hub preserving stateful symmetry"
      }
    },
    "tgw-b": {
      id: "tgw-b",
      name: "Transit Gateway Region B (Dublin)",
      category: "AWS Networking Hub",
      icon: "aws-transit-gateway",
      summary: "Twin regional transit hub in Region B participating in cross-region peering.",
      details: {
        "Amazon Side ASN": "64512 (module default in both regions)",
        "Appliance Mode": "ENABLE on Security VPC Attachment",
        "Attachments": "Security VPC (10.20/16), Mgmt VPC (10.21/16), Spoke 1 (10.22/16), Spoke 2 (10.23/16)",
        "TGW Peering": "Accepter for inter-region peering from Region A",
        "Terraform Module": "modules/transit_gateway (invoked via aws.region_b provider)"
      }
    },
    "tgw-peering": {
      id: "tgw-peering",
      name: "Cross-Region TGW Peering (A ⇄ B)",
      category: "AWS Inter-Region Backbone",
      icon: "aws-transit-gateway-peering",
      summary: "Encrypted inter-region backbone over the AWS private network without exposing traffic to the public internet.",
      details: {
        "Traffic Flow 1": "Path A: Region B firewall mgmt ➔ Panorama in Region A (3978 / 28443). Path B: not needed for management (SCM is reached over the internet)",
        "Traffic Flow 2": "Active Directory replication DC A ⇄ DC B (directly over peering, not through the firewalls)",
        "Traffic Flow 3": "LDAP / DNS to both domain controllers",
        "Traffic Flow 4": "SSM jump host and admin panel reaching Region B units",
        "Source File": "cross_region.tf"
      }
    },
    "fw-pair-a": {
      id: "fw-pair-a",
      name: "VM-Series Active/Passive HA Pair (Region A)",
      category: "Palo Alto Networks NGFW",
      icon: "panw-vmseries",
      summary: "Two VM-Series firewalls across eu-central-1a/1b with HA1/HA2 state sync. On failover the AWS HA plugin moves the floating secondary IPs (EIP follows) and the TGW routes.",
      details: {
        "PAN-OS Version": "Path B: 12.2.4 minimum (image 12.2.3 ➔ in-place upgrade via SCM). Path A: pinned (default 11.1.15), Panorama ≥ FW",
        "EC2 Instance Type": "m5.xlarge (4 vCPUs, 16 GiB RAM)",
        "Preferred Active": "fw1 (lowest HA priority); preemption OFF (PANW guidance for AWS)",
        "Failover Automation": "PAN-OS AWS HA plugin, secondary-IP mode (plugin 6.2.1), IAM instance profile",
        "What Moves": "untrust .100 (carries the EIP) + trust .100 (AssignPrivateIpAddresses); both TGW-attachment route tables (ReplaceRoute)",
        "Measured": "Takeover 0.7–7.7 s; GP portal outage ~5 s per switchover",
        "HA1 Control Link": "eth0 (Management), TCP 28769, 28260 AND ICMP heartbeat",
        "HA2 Data Link": "eth1 (ethernet1/1, device_index=1, 10.10.30.0/24) – State Sync",
        "Trust Interface": "eth2 (ethernet1/2, device_index=2, 10.10.20.0/24) – floating 10.10.20.100",
        "Untrust Interface": "eth3 (ethernet1/3, device_index=3, 10.10.10.0/24) – floating 10.10.10.100 + EIP",
        "Loopback.1": "10.10.10.100/32 – GP portal & gateway binding",
        "Configured by": "Path A: Panorama (modules/panorama_config) + configure-ha.sh. Path B: SCM folder + scm-ha.sh",
        "Terraform Modules": "modules/firewall, modules/routing"
      }
    },
    "fw-pair-b": {
      id: "fw-pair-b",
      name: "VM-Series Active/Passive HA Pair (Region B)",
      category: "Palo Alto Networks NGFW",
      icon: "panw-vmseries",
      summary: "Second HA pair in Region B. Serves its own nearest GA clients (gw-b) and takes over Region A's clients when Region A is unhealthy.",
      details: {
        "PAN-OS Version": "Same release as Region A (path B: 12.2.4)",
        "Addressing": "Security VPC 10.20.0.0/16, floating 10.20.10.100 (untrust) / 10.20.20.100 (trust), mgmt 10.20.0.11/.12",
        "Management (path A)": "Registered in the Region A Panorama over TGW peering (register-fw-panorama.sh)",
        "Management (path B)": "Same SCM folder as Region A; region values as per-device overrides; HA from SCM",
        "GP": "Gateway gw-b (pool 10.20.200.0/24, DNS 10.23.0.10 then 10.13.0.10); every portal lists gw-a + gw-b",
        "Terraform Module": "modules/region_stack (enable_region_b)"
      }
    },
    "panorama": {
      id: "panorama",
      name: "Panorama Central Management (Path A)",
      category: "Palo Alto Networks Central Mgmt",
      icon: "panw-panorama",
      mgmtPath: "A",
      summary: "Path A: a single self-hosted Panorama instance governing all firewalls in both AWS regions. Not deployed in path B (Strata Cloud Manager).",
      details: {
        "PAN-OS Version": "Pinned (default 11.1.15); rule: Panorama version >= managed FW version",
        "Instance Type": "m5.4xlarge (16 vCPUs, 64 GiB RAM)",
        "Logging Storage": "2000 GB (2 TB) EBS gp3 dedicated logging volume",
        "Private IP": "10.11.0.10 (Management VPC, AZ a)",
        "Hierarchy": "Template Stack: AWS-Transit-Stack, Device Group: AWS-Transit-DG",
        "Activation": "Manual serial + licence + device cert (OTP) — AWS has no Panorama bootstrap",
        "Terraform Workspace": "phase2-panorama-config/ (isolated state for panos provider)",
        "Admin Access": "No public IP – port forwarding via SSM Jump Host",
        "ADR Justification": "ADR D6 – single source of truth for security policies and certificates"
      }
    },
    "ssm-jumphost": {
      id: "ssm-jumphost",
      name: "SSM Jump Host (Zero-Bastion)",
      category: "AWS Security / Management",
      icon: "aws-ssm",
      summary: "Internal host for API automation and administrative tunnelling without exposing ports to the public internet (PAN-OS has no SSM agent).",
      details: {
        "Operating System": "Amazon Linux 2023 with AWS Systems Manager (SSM) Agent",
        "IAM Permissions": "AmazonSSMManagedInstanceCore policy",
        "SSM Tunnels": "Path A: local 44300 ➔ Panorama:443. Both: SSH/XML API to the firewalls (HA, GP local config)",
        "Module": "Path A: inside modules/panorama. Path B: modules/ssm_jumphost",
        "ADR Justification": "ADR D8 – eliminates public bastions, audited via AWS CloudTrail"
      }
    },
    "globalprotect-service": {
      id: "globalprotect-service",
      name: "GlobalProtect Portal & Gateways",
      category: "Palo Alto Networks Remote Access",
      icon: "panw-globalprotect",
      summary: "Portal behind Global Accelerator, one tunnel-mode gateway per region (gw-a, gw-b), GP-native gateway selection and AD group-gated authentication.",
      details: {
        "Ingress Point": "gp.<zone> ➔ Global Accelerator anycast ➔ floating .100 + EIP ➔ loopback.1",
        "Gateways": "gw-a.<zone> (Region A EIP), gw-b.<zone> (Region B EIP) — listed on every portal",
        "Protocols": "SSL-VPN (TCP 443) and IPSec (UDP 4501)",
        "Client Pools": "10.10.200.0/24 (Region A), 10.20.200.0/24 (Region B) – non-overlapping",
        "Split Tunneling": "Full tunnel by default (0.0.0.0/0) — ALL client traffic egresses via the firewall EIP and is inspected",
        "Client DNS": "DC as primary (10.13.0.10 on gw-a, 10.23.0.10 on gw-b), suffix panw.labs",
        "Certificate": "Let's Encrypt wildcard (module custom_domain) covers portal and gateways",
        "Authentication": "LDAP profile gated by Active Directory 'vpnusers' group",
        "Gateway Failover": "Native GP agent selection (SSL response time)",
        "Config": "Path A: modules/panorama_config/gp.tf + raw-XML tunnel node. Path B: scm-gp-local.sh on EACH unit"
      }
    },
    "nlb-a": {
      id: "nlb-a",
      name: "App NLB (Website Origin)",
      category: "AWS Load Balancing",
      icon: "aws-nlb",
      summary: "Network Load Balancer that is CloudFront's origin for the test website. It targets the floating VIP on the active firewall, so traffic is inspected and DNATed to Apache.",
      details: {
        "Target": "Floating VIP 10.10.10.100:80 (follows the active unit), health check :80",
        "Security Group": "Admits only CloudFront's origin-facing managed prefix list (app_nlb_cloudfront_only, default on)",
        "Effect": "The site cannot be reached around CloudFront and its WAF",
        "Coexistence": "GP :443 and app :80 share .100 on the same firewall",
        "Terraform Module": "modules/loadbalancer"
      }
    },
    "untrust-a": {
      id: "untrust-a",
      name: "Untrust Floating IP .100 + EIP (Region A)",
      category: "AWS Elastic IP / HA",
      icon: "panw-globalprotect",
      summary: "The floating secondary IP 10.10.10.100 on the active unit's untrust ENI. The public EIP is associated with it, so it moves together with the IP on failover.",
      details: {
        "Address": "10.10.10.100 (secondary, never primary) + Elastic IP",
        "Serves": "GP portal + gw-a (loopback.1), website NLB target :80",
        "Failover": "AssignPrivateIpAddresses (allow-reassignment) by the new active unit; EIP follows",
        "GA": "Region A endpoint group (traffic dial 100%), TCP 443 health check every 10 s"
      }
    },
    "trust-a": {
      id: "trust-a",
      name: "Trust ENI & Floating .100 (Region A)",
      category: "AWS Routing / HA",
      icon: "aws-transit-gateway",
      summary: "The TGW-facing dataplane ENI. It carries a floating secondary IP so that the HA plugin also rewrites the TGW-attachment routes on failover.",
      details: {
        "Address": "10.10.20.100 floating secondary on the active unit's trust ENI",
        "Routes": "0.0.0.0/0 in both TGW-attachment route tables ➔ active unit's trust ENI",
        "Failover": "ReplaceRoute by the new active unit (seen in CloudTrail ~6 s after a suspend)",
        "Why the IP": "The plugin only rewrites routes pointing at ENIs it moves IPs from; without it spoke/east-west traffic was black-holed",
        "Terraform": "aws_route ignores network_interface_id (the plugin owns it at runtime)"
      }
    },
    "dc-b": {
      id: "dc-b",
      name: "Windows DC Replica (Region B)",
      category: "Identity & Directory",
      icon: "aws-directory-service",
      summary: "Additional domain controller for panw.labs in Region B spoke 2, so authentication and DNS keep working when Region A is gone.",
      details: {
        "Private IP": "10.23.0.10",
        "Role": "Additional DC (region_b_create_dc = true), promotion 25–40 min",
        "Replication": "AD multi-master over TGW peering (directly, not through the firewalls); repadmin /replsummary: 0 fails",
        "Used by": "Region B firewalls' LDAP; primary DNS for gw-b clients; secondary DNS for gw-a clients",
        "Terraform Module": "modules/spoke2_dc via modules/region_stack"
      }
    },
    "gp-client": {
      id: "gp-client",
      name: "GlobalProtect Clients",
      category: "Remote Users",
      icon: "user-client",
      summary: "Remote users running the GlobalProtect agent. They connect to the portal gp.<zone> (Global Accelerator) and then to the best available gateway.",
      details: {
        "Portal": "gp.<zone> ➔ GA anycast ➔ nearest healthy region",
        "Gateways": "gw-a / gw-b, chosen by SSL response time",
        "Tunnel": "Full tunnel; client gets 10.10.200.x (A) or 10.20.200.x (B)",
        "Test user": "gpuser (AD group vpnusers)"
      }
    },
    "web-user": {
      id: "web-user",
      name: "Internet Browser Users",
      category: "Public / Admin Users",
      icon: "user-client",
      summary: "Browser traffic to the three public web endpoints: the test website, the admin panel (path B) and Guacamole.",
      details: {
        "Website": "https://website.<zone> ➔ CloudFront + WAF",
        "Admin Panel": "https://panel.<zone> ➔ ALB + WAF (path B)",
        "Guacamole": "https://rdp.<zone>/guacamole/ ➔ ALB + TOTP",
        "WAF geo rule": "Only waf_allowed_countries (lab: Poland) reach the website and panel"
      }
    },
    "spoke1-app": {
      id: "spoke1-app",
      name: "Spoke 1 — Apache Web Application",
      category: "Workload VPC",
      icon: "aws-ec2",
      summary: "Apache HTTP on EC2 in a private subnet: the origin behind https://website.<zone>, reachable only through CloudFront, the NLB and the firewalls.",
      details: {
        "VPC Addressing": "10.12.0.0/16 (Workload Subnet: 10.12.0.0/24)",
        "Private IP": "10.12.0.10",
        "Egress Routing": "Default route 0.0.0.0/0 to Transit Gateway (central inspection)",
        "Access Path": "CloudFront (+WAF) ➔ NLB ➔ FW DNAT (.100:80) ➔ Apache",
        "Terraform Module": "modules/spoke1_app"
      }
    },
    "spoke2-dc": {
      id: "spoke2-dc",
      name: "Spoke 2 — Windows Active Directory DC",
      category: "Identity & Directory",
      icon: "aws-directory-service",
      summary: "Windows Server 2022 domain controller (panw.labs) with a replica DC in Region B; spoke 2 also hosts the two AD CS hosts.",
      details: {
        "Domain Name": "panw.labs",
        "Private IP": "10.13.0.10 (Region A) & 10.23.0.10 (Region B - Replica)",
        "VPN Group": "cn=vpnusers,cn=users,dc=panw,dc=labs",
        "Panel Groups": "panel-admins, panel-operators (path B)",
        "Replication": "AD Multi-Master over Cross-Region TGW Peering",
        "Role in GP": "User authentication via LDAP (389); DNS for VPN clients",
        "Terraform Module": "modules/spoke2_dc"
      }
    }
  },

  // Interactive Traffic Flows (English)
  trafficFlows: [
    {
      id: "flow-gp-vpn",
      name: "1. GlobalProtect VPN Access (Client ➔ Tunnel ➔ Spokes)",
      color: "#00F0FF",
      description: "Remote client VPN tunnel establishment, AD authentication, and secure inspection to internal resources.",
      steps: [
        {
          title: "Anycast Portal Discovery",
          text: "The client connects to the GA anycast IP (TCP 443). GA sends it to its NEAREST HEALTHY region — a client in Poland lands on Region A (eu-central-1).",
          nodes: ["gp-client", "global-accelerator", "untrust-a"]
        },
        {
          title: "Loopback.1 Termination",
          text: "The floating 10.10.10.100 (with the EIP) is held by the active unit; the GlobalProtect portal and gateway gw-a listen on loopback.1.",
          nodes: ["untrust-a", "fw1-a"]
        },
        {
          title: "LDAP Group-Gated Authentication",
          text: "The firewall queries the Domain Controller in Spoke 2 (10.13.0.10) over TGW to verify group membership in 'vpnusers'.",
          nodes: ["fw1-a", "trust-a", "tgw-a", "dc-a"]
        },
        {
          title: "IP Pool Assignment & Workload Access",
          text: "Client receives an IP from 10.10.200.0/24 (full tunnel) and gains inspected access to corporate workloads via the trust ENI and TGW.",
          nodes: ["fw1-a", "trust-a", "tgw-a", "apache-a"]
        }
      ]
    },
    {
      id: "flow-inbound-app",
      name: "2. Test Website (WAF ➔ CloudFront ➔ NLB ➔ FW DNAT ➔ Apache)",
      color: "#FA582D",
      description: "https://website.<zone>: WAF and CloudFront at the edge, an NLB that only CloudFront can reach, then firewall inspection and DNAT to Apache.",
      steps: [
        {
          title: "WAF at the CloudFront Edge",
          text: "The browser hits CloudFront (ACM certificate). The CLOUDFRONT-scope WAF applies the geo allow-list (lab: Poland), the per-IP rate limit and the AWS managed rule groups.",
          nodes: ["web-user", "waf", "cloudfront"]
        },
        {
          title: "Origin: App NLB (CloudFront-only)",
          text: "CloudFront forwards to the app NLB. Its security group admits only CloudFront's origin-facing prefix list, so the site cannot be reached around CloudFront and WAF.",
          nodes: ["cloudfront", "nlb-a"]
        },
        {
          title: "NLB Target: Floating VIP",
          text: "The NLB targets 10.10.10.100:80 — the floating VIP on whichever unit is active.",
          nodes: ["nlb-a", "untrust-a", "fw1-a"]
        },
        {
          title: "L7 Inspection & DNAT + Symmetric SNAT",
          text: "The security rule matches the PRE-NAT destination (the VIP). The firewall DNATs to Apache (10.12.0.10) and SNATs to its trust IP, so Apache replies through it.",
          nodes: ["fw1-a", "trust-a"]
        },
        {
          title: "Delivery to Apache via TGW",
          text: "The packet reaches Spoke 1 Apache (10.12.0.10) via TGW. Return packets trace the exact same symmetric path back.",
          nodes: ["trust-a", "tgw-a", "apache-a"]
        }
      ]
    },
    {
      id: "flow-outbound-egress",
      name: "3. Outbound Internet Egress (Spoke ➔ TGW ➔ FW SNAT ➔ IGW)",
      color: "#10B981",
      description: "Centralized security inspection for outbound workload traffic heading to the public internet.",
      steps: [
        {
          title: "Outbound Request from Spoke",
          text: "An internal server in Spoke 1 sends packets to 0.0.0.0/0, guided by its subnet route table to Transit Gateway.",
          nodes: ["apache-a", "tgw-a"]
        },
        {
          title: "TGW Appliance Mode to Security VPC",
          text: "Route table tgw-rt-spoke forwards default traffic to the Security VPC attachment; the VPC route points at the ACTIVE unit's trust ENI.",
          nodes: ["tgw-a", "trust-a", "fw1-a"]
        },
        {
          title: "Policy Inspection & Source NAT",
          text: "In path B the Advanced IP Defense rules are evaluated first (alert or block for destinations on PANW's IP lists). Allowed traffic is SNATed to the floating .100 (EIP) and leaves via the IGW.",
          nodes: ["fw1-a", "untrust-a"]
        }
      ]
    },
    {
      id: "flow-east-west",
      name: "4. East-West Inter-Spoke (Spoke 1 ⇄ TGW ⇄ FW ⇄ Spoke 2)",
      color: "#A855F7",
      description: "Lateral inter-VPC segmentation between Spoke 1 (App) and Spoke 2 (Active Directory).",
      steps: [
        {
          title: "Initiation from Spoke 1",
          text: "Apache queries the Domain Controller in Spoke 2 (10.13.0.10). Packets hit Transit Gateway.",
          nodes: ["apache-a", "tgw-a"]
        },
        {
          title: "Forced Inspection via Spoke Route Table",
          text: "The TGW route table forces spoke-to-spoke lateral traffic through the Security VPC firewall cluster.",
          nodes: ["tgw-a", "trust-a", "fw1-a"]
        },
        {
          title: "Inter-Zone Security Inspection",
          text: "Firewall inspects traffic in the Trust security zone, enforces L7 rules, and returns allowed packets to TGW.",
          nodes: ["fw1-a", "trust-a", "tgw-a"]
        },
        {
          title: "Delivery to Spoke 2",
          text: "TGW delivers inspected packets to the Domain Controller in Spoke 2. Responses return symmetrically.",
          nodes: ["tgw-a", "dc-a"]
        }
      ]
    },
    {
      id: "flow-mgmt-plane",
      name: "5A. Management Plane — Path A (Panorama ➔ TGW Peering ➔ Region B)",
      color: "#F59E0B",
      mgmtPath: "A",
      description: "Path A: centralized policy push and log aggregation between the Region A Panorama and the Region B firewalls.",
      steps: [
        {
          title: "Central Policy Commit from Panorama",
          text: "The administrator commits in Panorama (10.11.0.10) in Region A; configure-panorama.sh polls every commit-all job to FIN/OK.",
          nodes: ["panorama", "tgw-a"]
        },
        {
          title: "Transit via Cross-Region Peering",
          text: "PAN-OS management traffic (3978 / 28443) crosses the private TGW peering to Region B.",
          nodes: ["tgw-a", "tgw-peering", "tgw-b"]
        },
        {
          title: "Delivery to Region B Management ENI",
          text: "Region B Transit Gateway routes traffic to eth0 (Management) of the Region B firewalls.",
          nodes: ["tgw-b", "fw1-b"]
        }
      ]
    },
    {
      id: "flow-mgmt-scm",
      name: "5B. Management Plane — Path B (Strata Cloud Manager ➔ both regions)",
      color: "#F59E0B",
      mgmtPath: "B",
      collapseSecurity: true,
      description: "Path B: one SCM folder configures all four units; region values come from per-device variables. No Panorama, no peering needed for management.",
      steps: [
        {
          title: "First Boot: Register to SCM",
          text: "init-cfg carries panorama-server=cloud and the registration PIN: each firewall fetches its device certificate and connects outbound to its SCM tenant. scm-onboard-fw.sh moves it into the folder.",
          nodes: ["fw-pair-a", "scm"]
        },
        {
          title: "One Folder, Per-Device Variables",
          text: "phase2-scm-config/ defines zones, interfaces, the ARE logical router, NAT and policy once; the floating IP, next hops and gateway differ per device (scm_variable device = overrides).",
          nodes: ["scm", "fw-pair-a", "scm", "fw-pair-b"]
        },
        {
          title: "Push + HA from SCM",
          text: "scm-ha.sh writes both pairs' HA configurations into SCM, then a single scm-push.sh carries everything and waits until every firewall's local commit has finished.",
          nodes: ["scm", "fw-pair-a", "scm", "fw-pair-b"]
        },
        {
          title: "Device-Local GlobalProtect",
          text: "SCM has no NGFW portal/gateway object, so scm-gp-local.sh builds GP over the XML API on EACH unit (via the SSM jump host). Local config survives SCM pushes.",
          nodes: ["ssm-jumphost", "tgw-a", "fw-pair-a"]
        }
      ]
    },
    {
      id: "flow-ad-replication",
      name: "6. Active Directory Replication & Resilient LDAP",
      color: "#EC4899",
      description: "Continuous multi-master directory synchronization across regions and resilient LDAP fallback.",
      steps: [
        {
          title: "AD Multi-Master Directory Sync",
          text: "Accounts and groups (e.g. vpnusers) replicate between DC-A (10.13.0.10) and DC-B (10.23.0.10) directly over TGW peering — DC↔DC traffic does not cross the firewalls.",
          nodes: ["dc-a", "tgw-a", "tgw-peering", "tgw-b", "dc-b"]
        },
        {
          title: "Both DCs in the LDAP Profiles",
          text: "LDAP profiles on all firewalls list both DCs with a short bind timeout, and each region's GP gateway pushes its local DC as primary DNS.",
          nodes: ["fw1-a", "dc-a", "dc-b"]
        }
      ]
    },
    {
      id: "flow-guacamole",
      name: "7. Browser-RDP via Guacamole (ALB + TOTP ➔ FW ➔ DC)",
      color: "#22C55E",
      expandSecurity: true,
      description: "Admin RDP to the domain controller without exposing RDP: Guacamole behind an ALB with mandatory TOTP, and the RDP leg inspected by the firewalls.",
      steps: [
        {
          title: "HTTPS + TOTP at the ALB",
          text: "The admin opens https://rdp.<zone>/guacamole/ (ACM certificate). Login needs the generated password AND a TOTP code; there is no default guacadmin account.",
          nodes: ["web-user", "guacamole"]
        },
        {
          title: "RDP Leg into the TGW",
          text: "The Guacamole host in the mgmt VPC opens RDP towards the DC; the mgmt VPC route sends it to the Transit Gateway.",
          nodes: ["guacamole", "tgw-a", "trust-a"]
        },
        {
          title: "Inspected by the Firewall",
          text: "Rule guacamole-rdp-to-dc (trust➔trust, ms-rdp) sits above deny-all — deny-all also matches intrazone traffic. The session is logged.",
          nodes: ["trust-a", "fw1-a", "trust-a"]
        },
        {
          title: "Delivered to the DC",
          text: "The firewall hands the session back to TGW and on to the DC (10.13.0.10). Works identically in path A and path B.",
          nodes: ["trust-a", "tgw-a", "dc-a"]
        }
      ]
    },
    {
      id: "flow-panel",
      name: "8. Admin/Test Panel (WAF ➔ ALB ➔ AD login ➔ policy simulation)",
      color: "#38BDF8",
      mgmtPath: "B",
      collapseSecurity: true,
      description: "Path B: the panel authenticates against AD, asks the active firewall which rule a session would hit, and runs failover tests while watching AWS and GA.",
      steps: [
        {
          title: "WAF + ALB",
          text: "https://panel.<zone> passes the REGIONAL WAF (geo allow-list, rate limit, managed rules) and the panel ALB, which balances over two hosts in two AZs.",
          nodes: ["web-user", "waf", "admin-panel"]
        },
        {
          title: "AD Login Through the Firewalls",
          text: "NTLM bind to the DC (rule panel-ldap-to-dc); membership of panel-admins gives viewer, panel-operators operator rights.",
          nodes: ["admin-panel", "tgw-a", "fw-pair-a", "tgw-a", "dc-a"]
        },
        {
          title: "Policy Simulation",
          text: "The panel runs test security-policy-match on the ACTIVE unit (account panelro, operational commands only) and animates the rulebase walk — no traffic is sent.",
          nodes: ["admin-panel", "tgw-a", "fw-pair-a", "threat-prevention"]
        },
        {
          title: "Live Topology & Failover Tests",
          text: "It reads HA state from both regions' units, EC2 state and route targets from AWS, and GA endpoint health; test runs are stored in DynamoDB.",
          nodes: ["admin-panel", "global-accelerator", "admin-panel", "fw-pair-b"]
        }
      ]
    }
  ],

  // Interactive Failure Scenarios (English)
  scenarios: [
    {
      id: "scenario-ha-failover",
      name: "Scenario 1: Active Firewall Failure (Intra-Region HA)",
      tag: "Intra-Region HA",
      description: "The active unit in Region A fails (EC2 host crash, or the panel's HA / hard failover test).",
      scriptCommand: "panel ➔ Failover tests ➔ HA failover   (or: bash scripts/failover-test.sh ha a down)",
      steps: [
        {
          phase: "Initial State",
          status: "normal",
          message: "FW1 is active: it holds the floating secondary IPs untrust .100 (carrying the EIP: portal + gw-a) and trust .100, and both TGW-attachment route tables point at its trust ENI. FW2 is passive.",
          affectedNodes: ["fw1-a"]
        },
        {
          phase: "Failure Detection",
          status: "failure",
          message: "FW1 stops answering the HA1 ICMP heartbeat and hellos (TCP 28769/28260). FW2 declares the peer lost.",
          affectedNodes: ["fw1-a"]
        },
        {
          phase: "Role Promotion",
          status: "action",
          message: "FW2 becomes active. Its PAN-OS AWS HA plugin (secondary-IP mode) calls the EC2 API with its IAM instance profile.",
          affectedNodes: ["fw2-a"]
        },
        {
          phase: "AWS Datapath Remapping",
          status: "action",
          message: "1. AssignPrivateIpAddresses: untrust .100 and trust .100 move to FW2's ENIs — the EIP stays associated with untrust .100, so it moves too.<br/>2. ReplaceRoute: both TGW-attachment route tables now send 0.0.0.0/0 to FW2's trust ENI.<br/>CloudTrail: ~6 s after the suspend.",
          affectedNodes: ["untrust-a", "trust-a"]
        },
        {
          phase: "Traffic Restored",
          status: "restored",
          message: "Measured: takeover 0.7–7.7 s, GP portal unreachable ~5 s. FW1 rejoins as passive (preemption off); the panel's 'Align the pair' fails back on purpose.",
          affectedNodes: ["fw2-a"]
        }
      ]
    },
    {
      id: "scenario-region-outage",
      name: "Scenario 2: Whole-Region Outage (Global Accelerator)",
      tag: "Multi-Region",
      description: "Region A goes dark (the panel's Region outage test stops both units). GA marks it unhealthy after ONE failed 10 s check and moves its clients to Region B.",
      scriptCommand: "panel ➔ Failover tests ➔ Region outage   (or: bash scripts/failover-test.sh region a down)",
      steps: [
        {
          phase: "Normal: Nearest Healthy",
          status: "normal",
          message: "Both endpoint groups run at a 100% traffic dial. Each client goes to its nearest healthy region: users in Poland ➔ Region A (eu-central-1), users nearer Ireland ➔ Region B. No split, no priority.",
          affectedNodes: ["global-accelerator"],
          badges: { "global-accelerator": ["NEAREST HEALTHY", "#10B981"] }
        },
        {
          phase: "Region A Blackout",
          status: "failure",
          message: "Both Region A firewalls stop. The portal and gw-a on Region A's EIP stop answering.",
          affectedNodes: ["region-a", "fw1-a", "fw2-a"],
          badges: { "global-accelerator": ["CHECKING…", "#F59E0B"] }
        },
        {
          phase: "GA Health Check Fails",
          status: "action",
          message: "GA health-checks TCP 443 on each region's EIP every 10 s (the shortest interval GA allows). Threshold is 1: the first failed check marks Region A unhealthy — ~10 s detection. (With the default threshold 3 the measured portal outage was 73 s.)",
          affectedNodes: ["global-accelerator"],
          badges: { "global-accelerator": ["A UNHEALTHY", "#EF4444"] }
        },
        {
          phase: "Clients Move to Region B",
          status: "action",
          message: "GA now sends Region A's clients — e.g. everyone in Poland — to Region B over the same two anycast IPs. No DNS change. Trade-off of threshold 1: a single lost check also moves traffic.",
          affectedNodes: ["global-accelerator", "untrust-b"],
          badges: { "global-accelerator": ["ALL ➔ REGION B", "#00F0FF"] }
        },
        {
          phase: "GP Gateway Selection",
          status: "action",
          message: "The portal, now answered by Region B, lists gw-a and gw-b; agents that lose gw-a pick gw-b by SSL response time.",
          affectedNodes: ["gp-client", "fw1-b"],
          badges: { "global-accelerator": ["ALL ➔ REGION B", "#00F0FF"] }
        },
        {
          phase: "LDAP / DNS on the Replica DC",
          status: "restored",
          message: "Region B firewalls authenticate against the replica DC 10.23.0.10 (AD replication over TGW peering); gw-b clients already use it as primary DNS.",
          affectedNodes: ["fw1-b", "dc-b"],
          badges: { "global-accelerator": ["ALL ➔ REGION B", "#00F0FF"] }
        },
        {
          phase: "Recovery",
          status: "normal",
          message: "When Region A passes a health check again, its nearby clients return to it (nearest healthy). The panel test waits for a clean active/passive pair and fails back.",
          affectedNodes: ["global-accelerator"],
          badges: { "global-accelerator": ["A HEALTHY AGAIN", "#10B981"] }
        }
      ]
    },
    {
      id: "scenario-panorama-outage",
      name: "Scenario 3A: Panorama Outage (Path A)",
      tag: "Management Plane · A",
      mgmtPath: "A",
      description: "Stopping the Panorama instance for maintenance or an unexpected failure.",
      scriptCommand: "aws ec2 stop-instances --instance-ids <panorama_id>",
      steps: [
        {
          phase: "Panorama Shutdown",
          status: "failure",
          message: "The Panorama instance in Region A is halted. The web GUI and XML API become temporarily unavailable.",
          affectedNodes: ["panorama"]
        },
        {
          phase: "Dataplane Autonomy",
          status: "restored",
          message: "VM-Series firewalls in both regions keep processing traffic from their local running configuration. GlobalProtect and inspection are uninterrupted; only config changes and central logging wait.",
          affectedNodes: ["fw1-a", "fw1-b"]
        }
      ]
    },
    {
      id: "scenario-scm-outage",
      name: "Scenario 3B: SCM Unreachable (Path B)",
      tag: "Management Plane · B",
      mgmtPath: "B",
      focus: "scm",
      zoom: 0.95,
      description: "The firewalls lose their connection to Strata Cloud Manager (tenant issue or outbound path down).",
      steps: [
        {
          phase: "SCM Disconnected",
          status: "failure",
          message: "The four units show as disconnected in SCM. No folder push or SCM-driven upgrade can run.",
          affectedNodes: ["scm"],
          badges: { "scm": ["DISCONNECTED", "#EF4444"] }
        },
        {
          phase: "Dataplane Autonomy",
          status: "restored",
          message: "Both pairs keep forwarding from their running config, HA keeps working (it is device-to-device), and the device-local GlobalProtect config is untouched. scm-upgrade.sh refuses to start until every unit is connected again.",
          affectedNodes: ["fw-pair-a", "fw1-b"],
          badges: { "scm": ["DISCONNECTED", "#EF4444"] }
        }
      ]
    },
    {
      id: "scenario-waf-block",
      name: "Scenario 4: Website Request from Outside the Allow-List",
      tag: "Edge Security",
      focus: "waf",
      zoom: 1.2,
      description: "A request to https://website.<zone> from a country not in waf_allowed_countries, and an attempt to bypass CloudFront.",
      steps: [
        {
          phase: "Request at the Edge",
          status: "normal",
          message: "The request reaches CloudFront; the CLOUDFRONT-scope web ACL evaluates it before any origin fetch.",
          affectedNodes: ["web-user", "waf", "cloudfront"]
        },
        {
          phase: "geo-allow-only Blocks",
          status: "failure",
          message: "The source country is not in the allow-list (lab: Poland only), so WAF answers 403 at the edge. The NLB, the firewalls and Apache never see it; the block shows in CloudWatch and WAF sampled requests.",
          affectedNodes: ["waf"],
          badges: { "waf": ["403 GEO BLOCK", "#EF4444"] }
        },
        {
          phase: "Bypass Attempt",
          status: "failure",
          message: "Calling the NLB's DNS name directly fails: its security group admits only CloudFront's origin-facing prefix list.",
          affectedNodes: ["nlb-a"],
          badges: { "waf": ["403 GEO BLOCK", "#EF4444"] }
        },
        {
          phase: "Allowed Request",
          status: "restored",
          message: "A request from Poland that passes the rate limit and managed rules goes CloudFront ➔ NLB ➔ firewall DNAT ➔ Apache, inspected on the way.",
          affectedNodes: ["waf", "cloudfront", "fw-pair-a", "apache-a"],
          badges: { "waf": ["ALLOW (PL)", "#10B981"] }
        }
      ]
    },
    {
      id: "scenario-appliance-mode",
      name: "Scenario 5: Transit Gateway Appliance Mode Enforcement",
      tag: "Datapath Symmetry",
      description: "Demonstrating why appliance_mode_support = enable is mandatory for stateful next-generation firewalls.",
      steps: [
        {
          phase: "Failure Without Appliance Mode",
          status: "failure",
          message: "Outbound traffic from AZ-A traverses the firewall in AZ-A. Return packets from a server in AZ-B can be routed by a standard TGW to the AZ-B attachment, where no session state exists, and are dropped.",
          affectedNodes: ["tgw-a", "fw1-a"]
        },
        {
          phase: "Solution: Appliance Mode ENABLE",
          status: "restored",
          message: "TGW pins both directions of a flow to the same attachment ENI, so return packets come back through the firewall that holds the session.",
          affectedNodes: ["tgw-a", "fw1-a"]
        }
      ]
    }
  ]
};

// The Polish data set (js/data.js) is the fallback the app expects. Fill in any
// drawer entry, alias, flow, scenario or slide id it does not define yet with
// the English one, so a ?lang=pl view never renders a blank drawer or list item.
(function syncPolishFallback() {
  if (typeof ARCHITECTURE_DATA === "undefined") return;
  const pl = ARCHITECTURE_DATA, en = ARCHITECTURE_DATA_EN;
  pl.components = pl.components || {};
  for (const [id, c] of Object.entries(en.components)) {
    if (!pl.components[id]) pl.components[id] = c;
  }
  pl.componentAliases = Object.assign({}, en.componentAliases, pl.componentAliases || {});
  for (const key of ["trafficFlows", "scenarios", "presentationSlides"]) {
    pl[key] = pl[key] || [];
    const have = new Set(pl[key].map(x => x.id));
    en[key].forEach((x, i) => {
      if (have.has(x.id)) return;
      // Insert at the same position as in the English list where possible.
      pl[key].splice(Math.min(i, pl[key].length), 0, x);
      have.add(x.id);
    });
  }
})();
