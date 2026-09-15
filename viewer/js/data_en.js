/**
 * AWS VM-Series HA & Multi-Region GlobalProtect Architecture Data Model (English)
 * Based on https://github.com/mzalewski87/aws_ha_project
 */

const ARCHITECTURE_DATA_EN = {
  projectInfo: {
    title: "AWS VM-Series HA — Multi-Region GlobalProtect",
    subtitle: "Enterprise Resilient Architecture Presentation",
    repoUrl: "https://github.com/mzalewski87/aws_ha_project",
    author: "Mikołaj Zalewski",
    version: "v1.2",
    panosVersion: "11.1.15",
    panoramaVersion: "11.1.15",
    keyConcepts: [
      "Active/Passive VM-Series HA with PAN-OS AWS HA Plugin",
      "Multi-Region Resilience via AWS Global Accelerator Anycast",
      "Native GlobalProtect Gateway Failover (No external LB)",
      "Transit Gateway with Appliance Mode (Cross-AZ flow symmetry)",
      "Central Panorama with Zero-Bastion SSM Session Manager",
      "Resilient Active Directory Multi-Master Forest & LDAP Auth"
    ]
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
        <p>Deliver uninterrupted enterprise VPN access (<strong>GlobalProtect Portal + Gateway</strong>) for remote workforce and corporate traffic inspection that <strong>survives individual firewall failures, Availability Zone (AZ) outages, and catastrophic AWS regional disasters</strong>.</p>
        <div class="callout-box">
          <strong>Why is this unique?</strong> Traditional architectures often lose VPN connectivity during regional outages or rely on fragile DNS failover (vulnerable to ISP TTL caching). Here, multi-region failover occurs in &lt;30 seconds over stable Anycast IP addresses.
        </div>
      `
    },
    {
      id: "ha_choice",
      title: "2. HA Model: Active/Passive vs GWLB (ADR D1)",
      targetFocus: "region-a-security",
      zoomLevel: 1.35,
      content: `
        <h4>Architectural Decision Record (ADR D1)</h4>
        <p>Each region deploys an <strong>Active/Passive VM-Series pair</strong> with dedicated HA1 (control/heartbeat) and HA2 (state synchronization) links powered by the PAN-OS AWS HA Plugin.</p>
        <p><strong>Why NOT AWS Gateway Load Balancer (GWLB)?</strong></p>
        <ul>
          <li>GWLB is a transparent "bump-in-the-wire" mechanism using GENEVE encapsulation and lacks public IP addresses.</li>
          <li>GlobalProtect terminates client VPN traffic on public IPs, requiring a deterministic, stable ingress point.</li>
          <li>Active/Passive with Floating secondary EIP provides seamless session failover without terminating established tunnels.</li>
        </ul>
      `
    },
    {
      id: "eni_quirks",
      title: "3. ENI Interface Ordering & AWS Quirks",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.5,
      content: `
        <h4>PAN-OS Platform Requirements on AWS EC2</h4>
        <p>Strict interface ordering (device_index) is mandatory for proper datapath and state sync:</p>
        <ul>
          <li><code>device_index=0</code> (eth0) ➔ <strong>Management (HA1)</strong>: Control plane, ICMP echo, and TCP 28769/28260.</li>
          <li><code>device_index=1</code> (eth1) ➔ <strong>HA2 (Data Link)</strong>: AWS requirement – firewall port <code>ethernet1/1</code> MUST be bound to HA2!</li>
          <li><code>device_index=2</code> (eth2) ➔ <strong>Trust (ethernet1/2)</strong>: Transit Gateway dataplane attachment (source/dest check = off).</li>
          <li><code>device_index=3</code> (eth3) ➔ <strong>Untrust (ethernet1/3)</strong>: Public traffic, floating IP <code>10.10.10.100</code> bound to <strong>Loopback.1</strong> in PAN-OS.</li>
        </ul>
      `
    },
    {
      id: "tgw_appliance",
      title: "4. Transit Gateway & Appliance Mode (ADR D5)",
      targetFocus: "tgw-a",
      zoomLevel: 1.4,
      content: `
        <h4>Central Hub & Stateful Flow Symmetry</h4>
        <p>All VPCs in the region (Security, Mgmt, Spoke 1, Spoke 2) attach to the AWS Transit Gateway.</p>
        <div class="callout-box warning">
          <strong>Mandatory Flag:</strong> <code>appliance_mode_support = enable</code> on the Security VPC Attachment.
        </div>
        <p>Without Appliance Mode, return traffic in a Multi-AZ architecture can route back through an alternate firewall in a different AZ, causing instant session drops (TCP RST) by stateful inspection. Appliance Mode forces strict bidirectional symmetry across AZs!</p>
      `
    },
    {
      id: "mgmt_panorama",
      title: "5. Central Management: Panorama & Zero-Bastion (ADR D6, D8)",
      targetFocus: "panorama",
      zoomLevel: 1.35,
      content: `
        <h4>Single Panorama Instance Across All Regions</h4>
        <p>One Panorama instance (<code>m5.4xlarge</code>, 2 TB dedicated logging EBS) in Region A governs all firewalls across regions via encrypted private TGW Peering.</p>
        <h4>Zero-Bastion Security Posture</h4>
        <p>No public SSH or HTTPS management ports exist. All administrative access (Terraform <code>panos</code> provider, XML API, GUI) is tunneled through <strong>AWS SSM Session Manager Port Forwarding</strong> via an internal SSM Jump Host.</p>
      `
    },
    {
      id: "multi_region_ga",
      title: "6. Multi-Region Resilience: Global Accelerator (ADR D3)",
      targetFocus: "global-accelerator",
      zoomLevel: 1.25,
      content: `
        <h4>Instant Regional Failover over Anycast</h4>
        <p><strong>AWS Global Accelerator</strong> provides 2 static Anycast IP addresses serving as the GlobalProtect Portal ingress:</p>
        <ul>
          <li>Anycast routes users over the high-speed AWS global backbone to the nearest healthy region.</li>
          <li>Continuous TCP 443 health checks monitor regional portal availability.</li>
          <li>In a catastrophic loss of Region A, traffic fails over to Region B in <strong>&lt;30 seconds</strong>, completely bypassing ISP DNS cache delays!</li>
        </ul>
      `
    },
    {
      id: "gp_native_failover",
      title: "7. Native GlobalProtect Gateway Selection (ADR D4)",
      targetFocus: "global",
      zoomLevel: 1.1,
      content: `
        <h4>No External Load Balancers in Front of VPN Gateways</h4>
        <p>The GlobalProtect Portal issues a dynamic Gateway List to client agents:</p>
        <ul>
          <li>Region A Gateway (<code>gw-eu-central.domain.com</code>) – Priority 1</li>
          <li>Region B Gateway (<code>gw-eu-west.domain.com</code>) – Priority 2</li>
        </ul>
        <p>The GP agent client autonomously measures SSL response time, connects to the optimal gateway, and executes zero-touch failover if the primary gateway becomes unreachable.</p>
      `
    },
    {
      id: "ad_replication",
      title: "8. Replicated Identity: Active Directory DS",
      targetFocus: "dc-a",
      zoomLevel: 1.2,
      content: `
        <h4>Independent Authentication During Regional Disaster</h4>
        <p>Spoke 2 in Region A hosts the primary Domain Controller (<code>panw.labs</code>, <code>10.13.0.10</code>), and Region B hosts the replica controller (<code>10.23.0.10</code>).</p>
        <ul>
          <li>Native AD Multi-Master Replication over private cross-region TGW Peering.</li>
          <li>Firewall LDAP Server Profiles configure both DCs with an aggressive connection timeout (<code>bind_timelimit = 3s</code>).</li>
          <li>If Region A fails, LDAP queries on the surviving Region B firewall switch to the local replica DC in 3 seconds!</li>
        </ul>
      `
    },
    {
      id: "app_path",
      title: "9. Application Datapath: CloudFront ➔ NLB ➔ Apache",
      targetFocus: "nlb-a",
      zoomLevel: 1.3,
      content: `
        <h4>Multi-Layer Inspection for Inbound Workloads</h4>
        <p>Inbound web application traffic undergoes layered perimeter inspection:</p>
        <ol>
          <li>Public users hit <strong>CloudFront CDN</strong> (Edge caching, AWS Shield L3/L4 DDoS mitigation).</li>
          <li>CloudFront forwards requests to regional public <strong>Network Load Balancers (NLB)</strong>.</li>
          <li>NLB targets the Active Firewall Untrust Floating IP (<code>.100:80</code>).</li>
          <li>PAN-OS performs <strong>DNAT</strong> to Apache (<code>10.12.0.10</code>) AND <strong>SNAT</strong> with the Trust ENI IP (preventing return routing asymmetry).</li>
        </ol>
      `
    },
    {
      id: "summary_takeaways",
      title: "10. Client Value Proposition & Key Takeaways",
      targetFocus: "global",
      zoomLevel: 1.0,
      content: `
        <h4>Enterprise Business & Architectural Benefits</h4>
        <div class="benefits-grid">
          <div class="benefit-card">
            <div class="badge">99.999% SLA</div>
            <h5>Maximum Resilience</h5>
            <p>Automated tolerance to instance failure, AZ loss, and total regional blackout with zero manual engineering intervention.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">Zero Bastion</div>
            <h5>Hardened Security</h5>
            <p>Zero public management ports. IAM role-governed access auditable via AWS CloudTrail and SSM Session Manager.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">IaC Terraform</div>
            <h5>100% Repeatability</h5>
            <p>Fully codified AWS infrastructure and PAN-OS security configuration using shared Panorama templates and device groups.</p>
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
      summary: "Anycast routing service directing remote users to the nearest healthy GlobalProtect Portal endpoint across 2 static Anycast IPs.",
      details: {
        "Service Type": "AWS Global Accelerator (Global Plane, managed from us-west-2)",
        "Addressing": "2 static Anycast IPs (fixed, non-changing)",
        "Listeners": "TCP 443 (SSL Portal/VPN) + UDP 4501 (IPSec Portal fallback)",
        "Endpoint Groups": "Region A (Frankfurt EIP) + Region B (Dublin EIP)",
        "Health Checks": "TCP protocol, port 443, interval 10s, threshold 3 attempts",
        "Failover Speed": "< 30 seconds upon complete regional failure",
        "Terraform Module": "modules/global_accelerator",
        "ADR Justification": "ADR D3 – eliminates DNS caching and TTL delays by ISPs"
      }
    },
    "cloudfront": {
      id: "cloudfront",
      name: "AWS CloudFront CDN",
      category: "AWS Edge / CDN",
      icon: "aws-cloudfront",
      summary: "Global Content Delivery Network fronting inbound traffic to the internal Apache web application via regional NLB.",
      details: {
        "Origin": "Regional Network Load Balancer (NLB DNS Name)",
        "Edge Protocols": "HTTPS at edge (Redirect HTTP to HTTPS)",
        "DDoS Mitigation": "AWS Shield Standard (built-in L3/L4 protection)",
        "Terraform Module": "modules/cloudfront"
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
      summary: "Twin regional transit hub in the disaster recovery region participating in Cross-Region Peering.",
      details: {
        "Amazon Side ASN": "64513",
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
        "Traffic Flow 1": "Region B Firewall Mgmt ➔ Panorama in Region A (ports 3978 / 28443)",
        "Traffic Flow 2": "Active Directory Replication (Spoke 2 Region A ⇄ Spoke 2 Region B)",
        "Traffic Flow 3": "LDAP authentication queries to both domain controllers from all firewalls",
        "Traffic Flow 4": "SSM Jump Host tunnel for Region B HA automation (configure-ha.sh)",
        "Source File": "cross_region.tf"
      }
    },
    "fw-pair-a": {
      id: "fw-pair-a",
      name: "VM-Series Active/Passive HA Pair (Region A)",
      category: "Palo Alto Networks NGFW",
      icon: "panw-vmseries",
      summary: "Dual VM-Series firewall cluster across eu-central-1a and eu-central-1b with state synchronization and automated API failover.",
      details: {
        "PAN-OS Version": "11.1.15 (Marketplace BYOL)",
        "EC2 Instance Type": "m5.xlarge (4 vCPUs, 16 GiB RAM, sized for license tier)",
        "Primary Active Node": "fw1 (device-priority: 100, preemption: NO)",
        "Passive Standby Node": "fw2 (device-priority: 110)",
        "Failover Automation": "PAN-OS AWS HA Plugin (IAM role: AssociateAddress, ReplaceRoute)",
        "HA1 Control Link": "eth0 (Management), TCP 28769, 28260, ICMP heartbeat",
        "HA2 Data Link": "eth1 (ethernet1/1, device_index=1, 10.10.30.0/24) – State Sync",
        "Trust Interface": "eth2 (ethernet1/2, device_index=2, 10.10.20.0/24) – TGW Dataplane",
        "Untrust Interface": "eth3 (ethernet1/3, device_index=3, 10.10.10.0/24) – Floating EIP",
        "Loopback.1": "10.10.10.100/32 – dedicated binding for GP Portal & Gateway",
        "Terraform Modules": "modules/firewall & modules/panorama_config"
      }
    },
    "fw-pair-b": {
      id: "fw-pair-b",
      name: "VM-Series Active/Passive HA Pair (Region B)",
      category: "Palo Alto Networks NGFW",
      icon: "panw-vmseries",
      summary: "Standby firewall cluster in Region B, centrally governed by Panorama from Region A.",
      details: {
        "PAN-OS Version": "11.1.15",
        "Addressing": "Security VPC 10.20.0.0/16, Floating IP 10.20.10.100",
        "Management": "Registered in Region A Panorama via private TGW Peering",
        "Bootstrap Script": "scripts/register-fw-panorama.sh",
        "Terraform Module": "modules/region_stack (count = var.enable_region_b ? 1 : 0)"
      }
    },
    "panorama": {
      id: "panorama",
      name: "Panorama Central Management",
      category: "Palo Alto Networks Central Mgmt",
      icon: "panw-panorama",
      summary: "Single Panorama management plane instance governing all firewalls across both AWS regions.",
      details: {
        "PAN-OS Version": "11.1.15 (Rule: Panorama version >= Managed FW version)",
        "Instance Type": "m5.4xlarge (16 vCPUs, 64 GiB RAM)",
        "Logging Storage": "2000 GB (2 TB) EBS GP3 dedicated logging volume",
        "Private IP": "10.11.0.10 (Management VPC, AZ a)",
        "Hierarchy": "Template Stack: AWS-Transit-Stack, Device Group: AWS-Transit-DG",
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
      summary: "Internal host facilitating API automation and administrative tunneling without exposing ports to the public internet.",
      details: {
        "Operating System": "Amazon Linux 2023 with AWS Systems Manager (SSM) Agent",
        "IAM Permissions": "AmazonSSMManagedInstanceCore policy",
        "SSM Tunnels": "Local 44300 ➔ Panorama:443, Port 2211 ➔ FW1:22, Port 2212 ➔ FW2:22",
        "Helper Script": "scripts/configure-panorama.sh tunnel",
        "ADR Justification": "ADR D8 – eliminates public bastions, audited via AWS CloudTrail"
      }
    },
    "globalprotect-service": {
      id: "globalprotect-service",
      name: "GlobalProtect Portal & Gateway",
      category: "Palo Alto Networks Remote Access",
      icon: "panw-globalprotect",
      summary: "Highly resilient next-gen VPN service featuring dynamic gateway selection and Active Directory group-gated authentication.",
      details: {
        "Ingress Point": "AWS Global Accelerator Anycast ➔ Untrust Floating IP (.100) ➔ Loopback.1",
        "Protocols": "SSL-VPN (TCP 443) and IPSec (UDP 4501)",
        "Client Pools": "10.10.200.0/24 (Region A), 10.20.200.0/24 (Region B) – non-overlapping",
        "Split Tunneling": "Enterprise 10.0.0.0/8 through tunnel, general internet split-tunneled",
        "Authentication": "LDAP profile gated by Active Directory 'vpnusers' group",
        "Gateway Failover": "Native GP agent probe (measures SSL response time)",
        "Config File": "modules/panorama_config/gp.tf"
      }
    },
    "spoke1-app": {
      id: "spoke1-app",
      name: "Spoke 1 — Apache Web Application",
      category: "Workload VPC",
      icon: "aws-ec2",
      summary: "Apache HTTP service on EC2 in private subnet, reachable via CloudFront CDN and regional NLB.",
      details: {
        "VPC Addressing": "10.12.0.0/16 (Workload Subnet: 10.12.0.0/24)",
        "Private IP": "10.12.0.10",
        "Egress Routing": "Default route 0.0.0.0/0 to Transit Gateway (central inspection)",
        "Access Path": "CloudFront ➔ NLB ➔ FW DNAT (.100:80) ➔ Apache",
        "Terraform Module": "modules/spoke1_app"
      }
    },
    "spoke2-dc": {
      id: "spoke2-dc",
      name: "Spoke 2 — Windows Active Directory DC",
      category: "Identity & Directory",
      icon: "aws-directory-service",
      summary: "Windows Server 2022 domain controller (panw.labs) with multi-master replication to Region B.",
      details: {
        "Domain Name": "panw.labs",
        "Private IP": "10.13.0.10 (Region A) & 10.23.0.10 (Region B - Replica)",
        "VPN Group": "cn=vpnusers,cn=users,dc=panw,dc=labs",
        "Replication": "AD Multi-Master over Cross-Region TGW Peering",
        "Role in GP": "User authentication via LDAP protocol (port 389)",
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
          text: "Remote user connects to AWS Global Accelerator Anycast IP (TCP 443). Traffic routes over the AWS backbone to the nearest healthy region (Region A).",
          nodes: ["gp-client", "global-accelerator", "untrust-a"]
        },
        {
          title: "Loopback.1 Termination",
          text: "Packets arriving at Untrust forward to loopback.1 (10.10.10.100), where the GlobalProtect Portal and Gateway listen.",
          nodes: ["untrust-a", "fw1-a"]
        },
        {
          title: "LDAP Group-Gated Authentication",
          text: "The firewall queries the Domain Controller in Spoke 2 (10.13.0.10) over TGW to verify group membership in 'vpnusers'.",
          nodes: ["fw1-a", "trust-a", "tgw-a", "dc-a"]
        },
        {
          title: "IP Pool Assignment & Workload Access",
          text: "Client receives an IP from 10.10.200.0/24 and gains inspected access to corporate workloads (e.g. Apache in Spoke 1) via Trust ENI and TGW.",
          nodes: ["fw1-a", "trust-a", "tgw-a", "apache-a"]
        }
      ]
    },
    {
      id: "flow-inbound-app",
      name: "2. Inbound Web Application (CloudFront ➔ NLB ➔ FW DNAT ➔ Apache)",
      color: "#FA582D",
      description: "Public client accessing internal web application with L7 threat inspection, DNAT, and symmetric reverse SNAT.",
      steps: [
        {
          title: "CloudFront CDN Edge Entry",
          text: "Public browser queries the CloudFront distribution. CDN handles TLS termination, DDoS mitigation, and forwards origin requests to NLB.",
          nodes: ["web-user", "cloudfront", "nlb-a"]
        },
        {
          title: "Target NLB: Untrust Floating IP",
          text: "NLB balances traffic across zones directly to the active firewall's Untrust floating IP (10.10.10.100:80).",
          nodes: ["nlb-a", "untrust-a", "fw1-a"]
        },
        {
          title: "L7 Inspection & DNAT + Symmetric SNAT",
          text: "Rule inbound-app-dnat translates destination to Apache (10.12.0.10). Crucially, the FW also applies SNAT with the Trust ENI IP so Apache replies to the FW rather than bypassing it!",
          nodes: ["fw1-a", "trust-a"]
        },
        {
          title: "Datapath Delivery to Apache via TGW",
          text: "Packet reaches Spoke 1 Apache (10.12.0.10) via TGW. Return packets trace the exact same symmetric path back.",
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
          text: "Route table tgw-rt-spoke forwards default traffic to the Security VPC attachment, preserving cross-AZ stateful symmetry.",
          nodes: ["tgw-a", "trust-a", "fw1-a"]
        },
        {
          title: "Security Policy Inspection & Source NAT",
          text: "PAN-OS verifies egress policy, applies SNAT using the public EIP, and dispatches packets via Untrust through the Internet Gateway.",
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
      name: "5. Management Plane (Panorama ➔ TGW Peering ➔ Region B FWs)",
      color: "#F59E0B",
      description: "Centralized policy push and log aggregation between Region A Panorama and Region B firewalls.",
      steps: [
        {
          title: "Central Policy Commit from Panorama",
          text: "Security administrator commits configuration in Panorama (10.11.0.10) in Region A.",
          nodes: ["panorama", "tgw-a"]
        },
        {
          title: "Transit via Encrypted Cross-Region Peering",
          text: "PAN-OS control plane packets (ports 3978 / 28443) cross the private AWS TGW Peering link to Region B.",
          nodes: ["tgw-a", "tgw-peering", "tgw-b"]
        },
        {
          title: "Delivery to Region B Management ENI",
          text: "Region B Transit Gateway routes traffic directly to eth0 (Management) of the Region B firewall.",
          nodes: ["tgw-b", "fw1-b"]
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
          text: "New user accounts and security groups (e.g. vpnusers) replicate automatically between DC-A (10.13.0.10) and DC-B (10.23.0.10).",
          nodes: ["dc-a", "tgw-a", "tgw-peering", "tgw-b", "dc-b"]
        },
        {
          title: "Concurrent Visibility in LDAP Profiles",
          text: "Shared Panorama template stacks configure LDAP profiles on all firewalls listing both DCs with a 3-second failover threshold.",
          nodes: ["fw1-a", "dc-a", "dc-b"]
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
      description: "Simulating sudden failure of FW1 in Region A (e.g. underlying EC2 hardware host crash).",
      scriptCommand: "AWS_PROFILE=awsha bash scripts/failover-test.sh ha a down",
      steps: [
        {
          phase: "Initial State",
          status: "normal",
          message: "FW1 is Active (processing traffic, owns EIP and secondary floating IP .100). FW2 stands by in Passive mode.",
          affectedNodes: ["fw1-a"]
        },
        {
          phase: "Failure Detection",
          status: "failure",
          message: "FW1 stops responding to ICMP heartbeats and HA1 control link hellos. FW2 declares loss of peer.",
          affectedNodes: ["fw1-a"]
        },
        {
          phase: "Role Promotion",
          status: "action",
          message: "FW2 promotes to Active. PAN-OS AWS HA Plugin immediately invokes AWS API using its assigned EC2 IAM instance profile.",
          affectedNodes: ["fw2-a"]
        },
        {
          phase: "AWS Datapath Remapping",
          status: "action",
          message: "1. ec2:AssociateAddress: Floating EIP is re-associated with FW2 Untrust ENI (.100).<br/>2. ec2:ReplaceRoute: TGW default route 0.0.0.0/0 is rewritten to FW2 Trust ENI.",
          affectedNodes: ["untrust-a", "trust-a"]
        },
        {
          phase: "Traffic Restored",
          status: "restored",
          message: "VPN tunnels and application traffic resume across FW2. Upon reboot, FW1 rejoins as Passive (preemption=no prevents flapping!).",
          affectedNodes: ["fw2-a"]
        }
      ]
    },
    {
      id: "scenario-region-outage",
      name: "Scenario 2: Catastrophic Regional Outage (Multi-Region DR)",
      tag: "Disaster Recovery",
      description: "Simulating total loss of Region A (major fiber cut or complete Frankfurt data center failure).",
      scriptCommand: "AWS_PROFILE=awsha bash scripts/failover-test.sh region a down",
      steps: [
        {
          phase: "Region A Blackout",
          status: "failure",
          message: "Both firewalls and the domain controller in Region A become unreachable. Region A portals and gateways go dark.",
          affectedNodes: ["region-a", "fw1-a", "fw2-a", "dc-a"]
        },
        {
          phase: "Global Accelerator Detection",
          status: "action",
          message: "Anycast TCP 443 health checks mark Region A endpoints unhealthy in under 30 seconds.",
          affectedNodes: ["global-accelerator"]
        },
        {
          phase: "Anycast Ingress Switch",
          status: "action",
          message: "AWS Global Accelerator instantly shifts 100% of user traffic to Region B (Dublin) endpoints with zero DNS modifications.",
          affectedNodes: ["global-accelerator", "region-b", "untrust-b"]
        },
        {
          phase: "Native GP Gateway Failover",
          status: "action",
          message: "GlobalProtect agents detect loss of priority 1 gateway (Frankfurt) and seamlessly establish tunnels to priority 2 gateway (Dublin).",
          affectedNodes: ["gp-client", "fw1-b"]
        },
        {
          phase: "LDAP Failover to Replica DC",
          status: "restored",
          message: "Region B firewalls fail to reach DC-A, wait 3 seconds (bind_timelimit), and transparently authenticate against the local replica DC (10.23.0.10)!",
          affectedNodes: ["fw1-b", "dc-b"]
        }
      ]
    },
    {
      id: "scenario-panorama-outage",
      name: "Scenario 3: Panorama Central Management Outage",
      tag: "Management Plane",
      description: "Stopping the Panorama instance for maintenance or unexpected failure.",
      scriptCommand: "aws ec2 stop-instances --instance-ids <panorama_id>",
      steps: [
        {
          phase: "Panorama Shutdown",
          status: "failure",
          message: "Panorama instance in Region A is halted. The web GUI and XML API become temporarily unavailable.",
          affectedNodes: ["panorama"]
        },
        {
          phase: "Dataplane Autonomy",
          status: "restored",
          message: "VM-Series firewalls in both regions continue processing traffic with 100% autonomy using locally cached running configuration. Remote access VPN and security inspection remain completely uninterrupted.",
          affectedNodes: ["fw1-a", "fw1-b"]
        }
      ]
    },
    {
      id: "scenario-appliance-mode",
      name: "Scenario 4: Transit Gateway Appliance Mode Enforcement",
      tag: "Datapath Symmetry",
      description: "Demonstrating why appliance_mode_support = enable is mandatory for stateful next-generation firewalls.",
      steps: [
        {
          phase: "Failure Without Appliance Mode",
          status: "failure",
          message: "Outbound traffic from AZ-A traverses FW1 in AZ-A. A server in AZ-B sends return packets that standard TGW routes to the FW in AZ-B. The firewall in AZ-B drops the session (TCP RST) due to missing state table entries.",
          affectedNodes: ["tgw-a", "fw1-a"]
        },
        {
          phase: "Solution: Appliance Mode ENABLE",
          status: "restored",
          message: "TGW pins bidirectional session state and forces return packets back through the EXACT SAME ENI and firewall that initiated the connection, guaranteeing 100% state table integrity!",
          affectedNodes: ["tgw-a", "fw1-a"]
        }
      ]
    }
  ]
};
