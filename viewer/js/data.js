/**
 * AWS VM-Series HA & Multi-Region GlobalProtect Architecture Data Model
 * Based on https://github.com/mzalewski87/aws_ha_project
 */

const ARCHITECTURE_DATA = {
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

  // Presentation slides for guided walkthrough
  presentationSlides: [
    {
      id: "intro",
      title: "1. Cel Projektu i Założenia Biznesowe",
      targetFocus: "global",
      zoomLevel: 1.0,
      content: `
        <h4>Biznesowy cel nadrzędny („North Star”)</h4>
        <p>Zapewnienie bezprzerwowego dostępu VPN (<strong>GlobalProtect Portal + Gateway</strong>) dla pracowników zdalnych oraz inspekcji ruchu korporacyjnego, który <strong>przetrwa awarię pojedynczego firewalla, strefy dostępności (AZ) oraz całego regionu AWS</strong>.</p>
        <div class="callout-box">
          <strong>Dlaczego to unikalne?</strong> Tradycyjne architektury często tracą dostęp do VPN przy awarii regionu lub wymagają uciążliwego przełączania DNS (narażonego na TTL). W tym projekcie failover między regionami zachodzi w czasie &lt;30s na stabilnych adresach Anycast.
        </div>
      `
    },
    {
      id: "ha_choice",
      title: "2. Model HA: Active/Passive zamiast GWLB (ADR D1)",
      targetFocus: "region-a-security",
      zoomLevel: 1.35,
      content: `
        <h4>Decyzja Architektoniczna ADR D1</h4>
        <p>W każdym regionie wdrożono <strong>parę Active/Passive VM-Series</strong> z dedykowanymi łączami HA1 (sterowanie/heartbeat) i HA2 (synchronizacja sesji) oraz wtyczką PAN-OS AWS HA Plugin.</p>
        <p><strong>Dlaczego NIE AWS Gateway Load Balancer (GWLB)?</strong></p>
        <ul>
          <li>GWLB to transparentny mechanizm „bump-in-the-wire” wykorzystujący enkapsulację GENEVE i nie posiada publicznych adresów IP.</li>
          <li>GlobalProtect terminujący ruch VPN klientów na publicznym IP wymaga stabilnego, adresowalnego punktu wejścia.</li>
          <li>Active/Passive z pływającym EIP gwarantuje przezroczyste przełączenie sesji bez przerywania tuneli VPN.</li>
        </ul>
      `
    },
    {
      id: "eni_quirks",
      title: "3. Anatomia Interfejsów ENI i Wymogi AWS",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.6,
      content: `
        <h4>Sztywne wymagania platformowe PAN-OS na AWS</h4>
        <p>Kolejność interfejsów (device_index) w AWS bezwzględnie warunkuje poprawne działanie:</p>
        <ul>
          <li><code>device_index=0</code> (eth0) ➔ <strong>Management (HA1)</strong>: Sterowanie, ping ICMP i porty TCP 28769/28260.</li>
          <li><code>device_index=1</code> (eth1) ➔ <strong>HA2 (Data Link)</strong>: Wymóg AWS – port <code>ethernet1/1</code> firewalla MUSI być przypisany do HA2!</li>
          <li><code>device_index=2</code> (eth2) ➔ <strong>Trust (ethernet1/2)</strong>: Połączenie ze szkieletem Transit Gateway (source/dest check = off).</li>
          <li><code>device_index=3</code> (eth3) ➔ <strong>Untrust (ethernet1/3)</strong>: Ruch publiczny, pływający adres wtórny <code>10.10.10.100</code> podpięty pod <strong>Loopback.1</strong> w PAN-OS dla GP.</li>
        </ul>
      `
    },
    {
      id: "tgw_appliance",
      title: "4. Transit Gateway & Appliance Mode (ADR D5)",
      targetFocus: "tgw-a",
      zoomLevel: 1.45,
      content: `
        <h4>Centralny Hub i Symetria Stanowa</h4>
        <p>Wszystkie VPC w regionie (Security, Mgmt, Spoke 1, Spoke 2) są dołączone do AWS Transit Gateway.</p>
        <div class="callout-box warning">
          <strong>Kluczowa flaga:</strong> <code>appliance_mode_support = enable</code> na attachmentcie Security VPC.
        </div>
        <p>Bez Appliance Mode ruch powrotny w architekturze Multi-AZ może powrócić przez inny firewall w innej strefie dostępności, co powoduje natychmiastowe zrzucenie sesji (TCP RST/Drop) przez stanowy firewall. Appliance Mode wymusza pełną symetrię przepływu!</p>
      `
    },
    {
      id: "mgmt_panorama",
      title: "5. Zarządzanie: Panorama & Zero-Bastion (ADR D6, D8)",
      targetFocus: "region-a-mgmt",
      zoomLevel: 1.4,
      content: `
        <h4>Pojedyncza Panorama dla Wszystkich Regionów</h4>
        <p>Jedna instancja Panorama (<code>m5.4xlarge</code>, dysk logów 2 TB) w Regionie A zarządza obiema parami firewalli poprzez prywatny backbone TGW Peering.</p>
        <h4>Bezpieczeństwo: Zero Bastion</h4>
        <p>Brak publicznych portów SSH i HTTPS do zarządzania. Cały dostęp (Terraform <code>panos</code> provider, XML API, konsola Panorama) realizowany jest przez <strong>AWS SSM Session Manager Port Forwarding</strong> za pośrednictwem SSM Jump Hosta.</p>
      `
    },
    {
      id: "multi_region_ga",
      title: "6. Odporność Multi-Region: Global Accelerator (ADR D3)",
      targetFocus: "global-accelerator",
      zoomLevel: 1.25,
      content: `
        <h4>Błyskawiczny Failover Całego Regionu</h4>
        <p><strong>AWS Global Accelerator</strong> udostępnia 2 statyczne adresy Anycast będące punktem wejścia dla Portalu GlobalProtect:</p>
        <ul>
          <li>Anycast kieruje użytkownika do najbliższego geograficznie, sprawnego regionu po szkielecie AWS.</li>
          <li>Ciągłe health checki TCP 443 monitorują dostępność portali regionalnych.</li>
          <li>W razie katastrofy Regionu A, Global Accelerator przełącza ruch na Region B w czasie <strong>&lt;30 sekund</strong>, ignorując cache DNS u dostawców ISP!</li>
        </ul>
      `
    },
    {
      id: "gp_native_failover",
      title: "7. Natywny Wybór Bram GlobalProtect (ADR D4)",
      targetFocus: "global",
      zoomLevel: 1.1,
      content: `
        <h4>Brak zewnętrznego load balancera przed bramami VPN</h4>
        <p>Portal GlobalProtect przekazuje agentom listę zewnętrznych bram (Gateway List):</p>
        <ul>
          <li>Region A Gateway (<code>gw-eu-central.domena.pl</code>) – Priorytet 1</li>
          <li>Region B Gateway (<code>gw-eu-west.domena.pl</code>) – Priorytet 2</li>
        </ul>
        <p>Agent GP samoczynnie testuje czasy odpowiedzi SSL (SSL response time) i łączy się z optymalną bramą, a w razie awarii sam wykonuje transparentny failover.</p>
      `
    },
    {
      id: "ad_replication",
      title: "8. Zreplikowana Tożsamość: Active Directory DS",
      targetFocus: "spoke2-both",
      zoomLevel: 1.2,
      content: `
        <h4>Niezależne Uwierzytelnianie przy Awarii Regionu</h4>
        <p>W Spoke 2 Regionu A działa podstawowy Kontroler Domeny (<code>panw.labs</code>, <code>10.13.0.10</code>), a w Regionie B kontroler repliki (<code>10.23.0.10</code>).</p>
        <ul>
          <li>Natywna replikacja Active Directory Multi-Master po Cross-Region TGW Peering.</li>
          <li>Firewalle w profilu LDAP mają zdefiniowane oba serwery DC z agresywnym timeoutem (<code>bind_timelimit = 3s</code>).</li>
          <li>Gdy Region A przestanie działać, zapytanie LDAP na ocalałym firewallu przełącza się na kontroler w Regionie B w 3 sekundy!</li>
        </ul>
      `
    },
    {
      id: "app_path",
      title: "9. Ścieżka Aplikacyjna: CloudFront ➔ NLB ➔ Apache",
      targetFocus: "app-flow-path",
      zoomLevel: 1.3,
      content: `
        <h4>Bezpieczny Dostęp do Aplikacji Wewnętrznej</h4>
        <p>Ruch do aplikacji w Spoke 1 przechodzi wielowarstwową ochronę:</p>
        <ol>
          <li>Klient odpytuje <strong>CloudFront CDN</strong> (Edge Caching, ochrona DDoS).</li>
          <li>CloudFront trafia do internet-facing <strong>Network Load Balancer (NLB)</strong>.</li>
          <li>NLB kieruje ruch na pływający adres IP Untrust (<code>.100:80</code>) aktywnego firewalla.</li>
          <li>Firewall wykonuje <strong>DNAT</strong> do Apache (<code>10.12.0.10</code>) ORAZ <strong>SNAT</strong> na interfejs Trust (zapewnia powrót symetryczny, zapobiegając ominięciu firewalla).</li>
        </ol>
      `
    },
    {
      id: "summary_takeaways",
      title: "10. Podsumowanie Wartości dla Klienta",
      targetFocus: "global",
      zoomLevel: 1.0,
      content: `
        <h4>Kluczowe Korzyści Biznesowo-Architektoniczne</h4>
        <div class="benefits-grid">
          <div class="benefit-card">
            <div class="badge">99.999% SLA</div>
            <h5>Maksymalna Odporność</h5>
            <p>Odporność na awarie pojedynczego FW, strefy AZ i całego regionu AWS bez konieczności interwencji inżyniera.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">Zero Bastion</div>
            <h5>Pancerne Bezpieczeństwo</h5>
            <p>Brak jakichkolwiek publicznych portów zarządzania. Dostęp przez IAM i SSM Session Manager.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">IaC Terraform</div>
            <h5>Pełna Powtarzalność</h5>
            <p>100% zautomatyzowane wdrożenie infrastruktury i konfiguracji PAN-OS (wspólne szablony Panorama).</p>
          </div>
        </div>
      `
    }
  ],

  // Detailed technical components for the Drill-Down panel
  components: {
    "global-accelerator": {
      id: "global-accelerator",
      name: "AWS Global Accelerator",
      category: "AWS Edge / Routing",
      icon: "aws-global-accelerator",
      summary: "Usługa Anycast kierująca klientów do najbliższego dostępnego punktu końcowego GP Portal na 2 statycznych adresach Anycast.",
      details: {
        "Typ usługi": "AWS Global Accelerator (Global Plane, zarządzenie z us-west-2)",
        "Adresacja": "2 statyczne adresy Anycast IP (niezmienne)",
        "Listenery": "TCP 443 (SSL Portal/VPN) + UDP 4501 (IPSec Portal fallback) + opcjonalnie TCP 80 (Redirect ALB)",
        "Endpoint Groups": "Region A (Frankfurt EIP) + Region B (Dublin EIP)",
        "Health Checks": "Protokół TCP, port 443, interwał 10s, próg awarii 3 nieudane próby",
        "Czas przełączenia (Failover)": "< 30 sekund w razie awarii całego regionu",
        "Moduł Terraform": "modules/global_accelerator",
        "Uzasadnienie ADR": "ADR D3 – eliminacja zależności od buforowania DNS i TTL u operatorów telekomunikacyjnych"
      }
    },
    "cloudfront": {
      id: "cloudfront",
      name: "AWS CloudFront CDN",
      category: "AWS Edge / CDN",
      icon: "aws-cloudfront",
      summary: "Globalna sieć CDN frontująca ruch do wewnętrznej aplikacji webowej (Apache w Spoke 1) poprzez regionalny NLB.",
      details: {
        "Origin": "Regionalny Network Load Balancer (NLB DNS Name)",
        "Protokoły": "HTTPS na brzegu (Redirect HTTP to HTTPS)",
        "Ochrona": "AWS Shield Standard (ochrona przed atakami L3/L4 DDoS)",
        "Moduł Terraform": "modules/cloudfront"
      }
    },
    "tgw-a": {
      id: "tgw-a",
      name: "Transit Gateway Region A (Frankfurt)",
      category: "AWS Networking Hub",
      icon: "aws-transit-gateway",
      summary: "Centralny hub tranzytowy łączący wszystkie VPC w regionie z wymuszonym trybem Appliance Mode dla Security VPC.",
      details: {
        "Amazon Side ASN": "64512",
        "Appliance Mode": "ENABLE na Security VPC Attachment (MANDATORY dla symetrii stanowej)",
        "Attachmenty": "Security VPC (10.10/16), Mgmt VPC (10.11/16), Spoke 1 (10.12/16), Spoke 2 (10.13/16)",
        "Tabele Tras": "tgw-rt-security (powrót do spoke'ów) oraz tgw-rt-spoke (0.0.0.0/0 i east-west kierowane do Security VPC)",
        "Połączenia Zewnętrzne": "TGW Peering Attachment do Regionu B (Dublin)",
        "Moduł Terraform": "modules/transit_gateway",
        "Uzasadnienie ADR": "ADR D5 – centralny punkt inspekcji i zachowanie symetrii sesji"
      }
    },
    "tgw-b": {
      id: "tgw-b",
      name: "Transit Gateway Region B (Dublin)",
      category: "AWS Networking Hub",
      icon: "aws-transit-gateway",
      summary: "Bliźniaczy hub tranzytowy w regionie zapasowym z dołączeniem do Cross-Region Peering.",
      details: {
        "Amazon Side ASN": "64513",
        "Appliance Mode": "ENABLE na Security VPC Attachment",
        "Attachmenty": "Security VPC (10.20/16), Mgmt VPC (10.21/16), Spoke 1 (10.22/16), Spoke 2 (10.23/16)",
        "TGW Peering": "Akceptor peer-ingu ab z Regionu A",
        "Moduł Terraform": "modules/transit_gateway (poprzez provider aws.region_b)"
      }
    },
    "tgw-peering": {
      id: "tgw-peering",
      name: "Cross-Region TGW Peering (A ⇄ B)",
      category: "AWS Inter-Region Backbone",
      icon: "aws-transit-gateway-peering",
      summary: "Szyfrowane połączenie międzyregionalne po prywatnym szkielecie AWS bez wystawiania ruchu na internet.",
      details: {
        "Przepływ 1": "Region B Firewall Mgmt ➔ Panorama w Regionie A (porty 3978 / 28443)",
        "Przepływ 2": "Replikacja Active Directory (Spoke 2 Region A ⇄ Spoke 2 Region B)",
        "Przepływ 3": "Zapytania LDAP do obu kontrolerów domeny z obu par firewalli",
        "Przepływ 4": "Tunel SSM Jump Host do konfiguracji HA w Regionie B (configure-ha.sh)",
        "Plik źródłowy": "cross_region.tf"
      }
    },
    "fw-pair-a": {
      id: "fw-pair-a",
      name: "VM-Series Active/Passive HA Pair (Region A)",
      category: "Palo Alto Networks NGFW",
      icon: "panw-vmseries",
      summary: "Para firewalli VM-Series w strefach eu-central-1a i eu-central-1b ze stanową synchronizacją i automatycznym failoverem.",
      details: {
        "Wersja PAN-OS": "11.1.15 (Marketplace BYOL)",
        "Typ instancji EC2": "m5.xlarge (4 vCPU, 16 GiB RAM, zgodne z licencją)",
        "Aktywny węzeł podstawowy": "fw1 (device-priority: 100, preemption: NO)",
        "Pasywny węzeł": "fw2 (device-priority: 110)",
        "Automatyzacja Failover": "PAN-OS AWS HA Plugin (IAM role: AssociateAddress, ReplaceRoute)",
        "Łącze HA1": "eth0 (Management), TCP 28769, 28260, ICMP echo heartbeat",
        "Łącze HA2": "eth1 (ethernet1/1, device_index=1, 10.10.30.0/24) – State Sync",
        "Interfejs Trust": "eth2 (ethernet1/2, device_index=2, 10.10.20.0/24) – TGW Facing",
        "Interfejs Untrust": "eth3 (ethernet1/3, device_index=3, 10.10.10.0/24) – Publiczny EIP",
        "Loopback.1": "10.10.10.100/32 – dedykowany bind dla GP Portal i Gateway",
        "Moduł Terraform": "modules/firewall & modules/panorama_config"
      }
    },
    "fw-pair-b": {
      id: "fw-pair-b",
      name: "VM-Series Active/Passive HA Pair (Region B)",
      category: "Palo Alto Networks NGFW",
      icon: "panw-vmseries",
      summary: "Zapasowa para firewalli w Regionie B, w pełni zarządzana przez Panoramę z Regionu A.",
      details: {
        "Wersja PAN-OS": "11.1.15",
        "Adresacja": "Security VPC 10.20.0.0/16, Floating IP 10.20.10.100",
        "Zarządzanie": "Zarejestrowana w Panoramie Regionu A przez TGW Peering",
        "Rejestracja": "scripts/register-fw-panorama.sh",
        "Moduł Terraform": "modules/region_stack (count = var.enable_region_b ? 1 : 0)"
      }
    },
    "panorama": {
      id: "panorama",
      name: "Panorama Central Management",
      category: "Palo Alto Networks Central Mgmt",
      icon: "panw-panorama",
      summary: "Pojedyncza instancja Panoramy zarządzająca wszystkimi firewallami w obu regionach AWS.",
      details: {
        "Wersja PAN-OS": "11.1.15 (Zasada: Wersja Panoramy >= wersji zarządzanych FW)",
        "Typ instancji": "m5.4xlarge (16 vCPU, 64 GiB RAM)",
        "Dysk Logów": "2000 GB (2 TB) EBS GP3 dedicated logging volume",
        "Prywatny adres IP": "10.11.0.10 (Management VPC, AZ a)",
        "Struktura Konfiguracji": "Template Stack: AWS-Transit-Stack, Device Group: AWS-Transit-DG",
        "Workspace Terraform": "phase2-panorama-config/ (odseparowany stan dla providera panos)",
        "Dostęp administracyjny": "Brak publicznego IP – port-forwarding przez SSM Jump Host",
        "Uzasadnienie ADR": "ADR D6 – pojedyncze źródło prawdy dla polityk bezpieczeństwa i certyfikatów"
      }
    },
    "ssm-jumphost": {
      id: "ssm-jumphost",
      name: "SSM Jump Host (Zero-Bastion)",
      category: "AWS Security / Management",
      icon: "aws-ssm",
      summary: "Wewnętrzny host ułatwiający automatyzację API i tunelowanie sesji administracyjnych bez otwierania portów do internetu.",
      details: {
        "System Operacyjny": "Amazon Linux 2023 z agentem AWS Systems Manager (SSM)",
        "Uprawnienia IAM": "AmazonSSMManagedInstanceCore",
        "Tunele SSM": "Lokalny port 44300 ➔ Panorama:443, Port 2211 ➔ FW1:22, Port 2212 ➔ FW2:22",
        "Skrypt pomocniczy": "scripts/configure-panorama.sh tunnel",
        "Uzasadnienie ADR": "ADR D8 – eliminacja publicznych maszyn typu Bastion, audytowalność przez AWS CloudTrail"
      }
    },
    "globalprotect-service": {
      id: "globalprotect-service",
      name: "GlobalProtect Portal & Gateway",
      category: "Palo Alto Networks Remote Access",
      icon: "panw-globalprotect",
      summary: "Wysoko dostępna usługa VPN nowej generacji z dynamicznym doborem bramy i uwierzytelnianiem Active Directory.",
      details: {
        "Punkt wejścia": "AWS Global Accelerator Anycast ➔ Untrust Floating IP (.100) ➔ Loopback.1",
        "Protokoły": "SSL-VPN (TCP 443) oraz IPSec (UDP 4501)",
        "Pula adresowa klientów": "10.10.200.0/24 (Region A), 10.20.200.0/24 (Region B) – brak nakładania",
        "Split Tunneling": "Domyślnie pełny tunel (0.0.0.0/0) — CAŁY ruch klienta, łącznie z internetem, wychodzi przez EIP firewalla i jest inspekowany",
        "Uwierzytelnianie": "Profil LDAP ze sprawdzaniem grupy AD 'vpnusers' (group-gated access)",
        "Failover Bramy": "Natywny mechanizm agenta GP (wybór najlepszej bramy wg SSL response time)",
        "Plik konfiguracyjny": "modules/panorama_config/gp.tf"
      }
    },
    "spoke1-app": {
      id: "spoke1-app",
      name: "Spoke 1 — Apache Web Application",
      category: "Workload VPC",
      icon: "aws-ec2",
      summary: "Aplikacja Apache hostowana na EC2 w prywatnej podsieci, dostępna przez CloudFront i NLB.",
      details: {
        "Adresacja VPC": "10.12.0.0/16 (Workload Subnet: 10.12.0.0/24)",
        "Prywatny IP": "10.12.0.10",
        "Routing Egress": "Default route 0.0.0.0/0 skierowany do Transit Gateway (pełna inspekcja)",
        "Ścieżka dostępu": "CloudFront ➔ NLB ➔ FW DNAT (.100:80) ➔ Apache",
        "Moduł Terraform": "modules/spoke1_app"
      }
    },
    "spoke2-dc": {
      id: "spoke2-dc",
      name: "Spoke 2 — Windows Active Directory DC",
      category: "Identity & Directory",
      icon: "aws-directory-service",
      summary: "Kontroler domeny Windows Server 2022 (panw.labs) z replikacją multi-master do Regionu B.",
      details: {
        "Domena": "panw.labs",
        "Prywatny IP": "10.13.0.10 (Region A) oraz 10.23.0.10 (Region B - Replika)",
        "Grupa uprawnień VPN": "cn=vpnusers,cn=users,dc=panw,dc=labs",
        "Replikacja": "AD Multi-Master po Cross-Region TGW Peering",
        "Rola w GP": "Uwierzytelnianie użytkowników VPN przez protokół LDAP (port 389)",
        "Moduł Terraform": "modules/spoke2_dc"
      }
    }
  },

  // Interactive Traffic Flows
  trafficFlows: [
    {
      id: "flow-gp-vpn",
      name: "1. GlobalProtect VPN Access (Client ➔ Tunnel ➔ Spokes)",
      color: "#00F0FF",
      description: "Przepływ zestawienia tunelu VPN przez klienta zdalnego, uwierzytelnienie w AD i dostęp do aplikacji wewnętrznej.",
      steps: [
        {
          title: "Zapytanie do Portalu Anycast",
          text: "Klient łączy się z adresem Anycast AWS Global Accelerator (TCP 443). Ruch trafia do najbliższego Regionu A.",
          nodes: ["gp-client", "global-accelerator", "eip-a", "untrust-a"]
        },
        {
          title: "Terminacja w Loopback.1",
          text: "Pakiety z Untrust trafiają na dedykowany interfejs loopback.1 (10.10.10.100), gdzie nasłuchuje Portal i Gateway.",
          nodes: ["untrust-a", "loopback-a", "fw1-a"]
        },
        {
          title: "Uwierzytelnienie LDAP w Spoke 2",
          text: "Firewall weryfikuje poświadczenia użytkownika przez LDAP w Kontrolerze Domeny (10.13.0.10) przez TGW.",
          nodes: ["fw1-a", "trust-a", "tgw-a", "dc-a"]
        },
        {
          title: "Przydział IP i Dostęp do Zasobów",
          text: "Klient otrzymuje IP z puli 10.10.200.0/24 i uzyskuje dostęp do zasobów wewnętrznych (np. Apache w Spoke 1) przez Trust ENI i TGW.",
          nodes: ["fw1-a", "trust-a", "tgw-a", "apache-a"]
        }
      ]
    },
    {
      id: "flow-inbound-app",
      name: "2. Inbound Web Application (CloudFront ➔ NLB ➔ FW DNAT ➔ Apache)",
      color: "#FA582D",
      description: "Dostęp użytkownika publicznego do aplikacji www z inspekcją L7, regułami DNAT oraz symetrycznym SNAT powrotnym.",
      steps: [
        {
          title: "Wejście przez CloudFront",
          text: "Użytkownik odpytuje domenę CloudFront. CDN buforuje treść statyczną i kieruje żądanie dynamiczne do origin NLB.",
          nodes: ["web-user", "cloudfront", "nlb-a"]
        },
        {
          title: "Target NLB: Untrust Floating IP",
          text: "NLB przekazuje ruch do pływającego adresu IP aktywnego firewalla (10.10.10.100:80).",
          nodes: ["nlb-a", "untrust-a", "fw1-a"]
        },
        {
          title: "Inspekcja i DNAT + SNAT na FW",
          text: "Reguła inbound-app-dnat tłumaczy cel na IP Apache (10.12.0.10). Kluczowe: FW nakłada też SNAT z adresem interfejsu Trust, aby Apache odesłał odpowiedź do FW, a nie bezpośrednio do NLB (zapobiega asymetrii!).",
          nodes: ["fw1-a", "trust-a"]
        },
        {
          title: "Dostarczenie do Apache przez TGW",
          text: "Pakiet trafia przez TGW do Spoke 1 Apache (10.12.0.10). Odpowiedź wraca symetrycznie tą samą drogą.",
          nodes: ["trust-a", "tgw-a", "apache-a"]
        }
      ]
    },
    {
      id: "flow-outbound-egress",
      name: "3. Outbound Internet Egress (Spoke ➔ TGW ➔ FW SNAT ➔ IGW)",
      color: "#10B981",
      description: "Inspekcja ruchu wychodzącego ze spoke'ów do internetu z centralną kontrolą bezpieczeństwa.",
      steps: [
        {
          title: "Żądanie wychodzące ze Spoke",
          text: "Serwer w Spoke 1 (np. aktualizacja pakietów) wysyła pakiet do 0.0.0.0/0 kierowany do TGW.",
          nodes: ["apache-a", "tgw-a"]
        },
        {
          title: "TGW Appliance Mode do Security VPC",
          text: "Tabela tgw-rt-spoke kieruje 0.0.0.0/0 do attachmentu Security VPC z zachowaniem symetrii stref AZ.",
          nodes: ["tgw-a", "trust-a", "fw1-a"]
        },
        {
          title: "Inspekcja Security Policy i SNAT",
          text: "PAN-OS sprawdza regułę spokes-outbound, nakłada SNAT z adresem EIP i wysyła pakiet przez Untrust do IGW.",
          nodes: ["fw1-a", "untrust-a", "igw-a", "internet"]
        }
      ]
    },
    {
      id: "flow-east-west",
      name: "4. East-West Inter-Spoke (Spoke 1 ⇄ TGW ⇄ FW ⇄ Spoke 2)",
      color: "#A855F7",
      description: "Inspekcja ruchu lateralnego pomiędzy podsieciami Spoke 1 (App) i Spoke 2 (Active Directory).",
      steps: [
        {
          title: "Inicjacja ze Spoke 1",
          text: "Aplikacja Apache odpytuje Kontroler Domeny w Spoke 2 (10.13.0.10). Ruch trafia do TGW.",
          nodes: ["apache-a", "tgw-a"]
        },
        {
          title: "Wymuszenie inspekcji przez TGW Spoke RT",
          text: "Trasa spoke-to-spoke w tabeli tgw-rt-spoke zmusza ruch do przejścia przez firewalle w Security VPC.",
          nodes: ["tgw-a", "trust-a", "fw1-a"]
        },
        {
          title: "Inspekcja reguł międzystrefowych",
          text: "Firewall filtruje ruch w strefie Trust zgodnie z polityką i odsyła dopuszczony pakiet z powrotem do TGW.",
          nodes: ["fw1-a", "trust-a", "tgw-a"]
        },
        {
          title: "Dostarczenie do Spoke 2",
          text: "TGW dostarcza ruch do Kontrolera Domeny w Spoke 2. Odpowiedź wraca symetrycznie.",
          nodes: ["tgw-a", "dc-a"]
        }
      ]
    },
    {
      id: "flow-mgmt-plane",
      name: "5. Management Plane (Panorama ➔ TGW Peering ➔ Region B FWs)",
      color: "#F59E0B",
      description: "Zarządzanie regułami i logami pomiędzy centralną Panoramą w Regionie A a firewallami w Regionie B.",
      steps: [
        {
          title: "Commit z Panoramy",
          text: "Administrator publikuje politykę w Panoramie (10.11.0.10) w Regionie A.",
          nodes: ["panorama", "tgw-a"]
        },
        {
          title: "Tranzyt przez Cross-Region Peering",
          text: "Pakiety sterujące PAN-OS (porty 3978 / 28443) przechodzą przez szyfrowany TGW Peering do Regionu B.",
          nodes: ["tgw-a", "tgw-peering", "tgw-b"]
        },
        {
          title: "Dostarczenie do Management ENI w Regionie B",
          text: "TGW Regionu B dostarcza konfigurację na interfejs eth0 (mgmt) firewalla w Regionie B.",
          nodes: ["tgw-b", "mgmt-b", "fw1-b"]
        }
      ]
    },
    {
      id: "flow-ad-replication",
      name: "6. Active Directory Replication & Resilient LDAP",
      color: "#EC4899",
      description: "Ciągła replikacja multi-master katalogu AD pomiędzy regionami oraz niezawodne odpytywanie LDAP.",
      steps: [
        {
          title: "Replikacja obiektów AD",
          text: "Nowi użytkownicy i grupy (np. vpnusers) replikują się automatycznie pomiędzy DC-A (10.13.0.10) a DC-B (10.23.0.10).",
          nodes: ["dc-a", "tgw-a", "tgw-peering", "tgw-b", "dc-b"]
        },
        {
          title: "Równoległa widoczność w profilu LDAP",
          text: "Wspólny szablon Panorama konfiguruje profile LDAP na obu firewallach z listą obu DC i 3-sekundowym limitem połączenia.",
          nodes: ["fw1-a", "dc-a", "dc-b"]
        }
      ]
    }
  ],

  // Interactive Failure Scenarios
  scenarios: [
    {
      id: "scenario-ha-failover",
      name: "Scenariusz 1: Awaria Aktywnego Firewalla (Intra-Region Failover)",
      tag: "Intra-Region HA",
      description: "Symulacja awarii instancji FW1 w Regionie A (np. crash sprzętowy EC2 lub awaria zasilania hosta).",
      scriptCommand: "AWS_PROFILE=awsha bash scripts/failover-test.sh ha a down",
      steps: [
        {
          phase: "Stan Początkowy",
          status: "normal",
          message: "FW1 jest węzłem Active (obsługuje ruch, posiada EIP i floating IP .100). FW2 czuwa w trybie Passive.",
          affectedNodes: ["fw1-a"]
        },
        {
          phase: "Wykrycie Awarii",
          status: "failure",
          message: "FW1 przestaje odpowiadać na pongi ICMP i zapytania kontrolne łącza HA1. FW2 stwierdza utratę węzła nadrzędnego.",
          affectedNodes: ["fw1-a", "ha1-a"]
        },
        {
          phase: "Przejęcie Roli (Promotion)",
          status: "action",
          message: "FW2 przechodzi w stan Active. Wtyczka PAN-OS AWS HA natychmiast wywołuje AWS API przez przypisany IAM Profile.",
          affectedNodes: ["fw2-a"]
        },
        {
          phase: "Re-mapowanie Zasobów AWS",
          status: "action",
          message: "1. ec2:AssociateAddress: EIP zostaje przypisany do interfejsu Untrust FW2 (.100).<br/>2. ec2:ReplaceRoute: Domyślna trasa TGW 0.0.0.0/0 zostaje przepisana na Trust ENI FW2.",
          affectedNodes: ["untrust-a", "trust-a", "eip-a"]
        },
        {
          phase: "Przywrócenie Ruchu",
          status: "restored",
          message: "Ruch VPN i aplikacji zostaje w pełni przywrócony przez FW2. Po ponownym uruchomieniu FW1 dołącza jako Passive (preemption=no zapobiega flappingowi!).",
          affectedNodes: ["fw2-a"]
        }
      ]
    },
    {
      id: "scenario-region-outage",
      name: "Scenariusz 2: Katastrofalna Awaria Całego Regionu (Multi-Region DR)",
      tag: "Disaster Recovery",
      description: "Symulacja całkowitego wyłączenia Regionu A (awaria sieci szkieletowej lub centrum danych we Frankfurcie).",
      scriptCommand: "AWS_PROFILE=awsha bash scripts/failover-test.sh region a down",
      steps: [
        {
          phase: "Awaria Regionu A",
          status: "failure",
          message: "Oba firewalle i kontroler domeny w Regionie A stają się niedostępne. Portale i bramy Regionu A gasną.",
          affectedNodes: ["region-a", "fw1-a", "fw2-a", "dc-a"]
        },
        {
          phase: "Detekcja Global Accelerator",
          status: "action",
          message: "Health checki Anycast (TCP 443) w ciągu < 30 sekund oznaczają Region A jako unhealthy.",
          affectedNodes: ["global-accelerator"]
        },
        {
          phase: "Przełączenie Ruchu Anycast",
          status: "action",
          message: "AWS Global Accelerator natychmiast przekierowuje 100% zapytań do Portalu na punkt końcowy Regionu B (Dublin) bez zmian w DNS.",
          affectedNodes: ["global-accelerator", "region-b", "untrust-b"]
        },
        {
          phase: "Natywny Failover Bramy GP",
          status: "action",
          message: "Agenci GlobalProtect stwierdzają brak łączności z bramą priorytetu 1 (Region A) i automatycznie łączą się z bramą priorytetu 2 (Region B).",
          affectedNodes: ["gp-client", "fw1-b"]
        },
        {
          phase: "LDAP Failover do Replikanta AD",
          status: "restored",
          message: "Firewall w Regionie B próbuje odpytać pierwszy DC (Region A), po 3 sekundach (bind_timelimit) przełącza zapytanie na lokalny DC (10.23.0.10). Użytkownik zostaje pomyślnie zalogowany!",
          affectedNodes: ["fw1-b", "dc-b"]
        }
      ]
    },
    {
      id: "scenario-panorama-outage",
      name: "Scenariusz 3: Awaria Panoramy (Dataplane vs Mgmt-Plane)",
      tag: "Management Isolation",
      description: "Zatrzymanie instancji Panorama w celach serwisowych lub w wyniku awarii.",
      scriptCommand: "aws ec2 stop-instances --instance-ids <panorama_id>",
      steps: [
        {
          phase: "Zatrzymanie Panoramy",
          status: "failure",
          message: "Instancja Panorama w Regionie A zostaje wyłączona. Interfejs GUI oraz API stają się niedostępne.",
          affectedNodes: ["panorama"]
        },
        {
          phase: "Autonomia Dataplane",
          status: "restored",
          message: "Firewalle VM-Series w obu regionach kontynuują pracę w 100% bez zakłóceń w oparciu o lokalną pamięć konfiguracji (running-config). Ruch VPN, inspekcja i reguły bezpieczeństwa działają w pełni transparentnie.",
          affectedNodes: ["fw1-a", "fw1-b"]
        }
      ]
    },
    {
      id: "scenario-appliance-mode",
      name: "Scenariusz 4: Rola Transit Gateway Appliance Mode",
      tag: "Network Symmetry",
      description: "Wyjaśnienie dlaczego flaga appliance_mode_support = enable jest krytyczna dla firewalli stanowych.",
      steps: [
        {
          phase: "Problem bez Appliance Mode",
          status: "failure",
          message: "Ruch wychodzący z AZ-A przechodzi przez FW1 w AZ-A. Odpowiedź z serwera w AZ-B standardowy TGW przekazuje do FW w AZ-B. Stanowy firewall w AZ-B nie zna tej sesji i natychmiast ZRZUCA PAKIET (TCP RST).",
          affectedNodes: ["tgw-a", "fw1-a"]
        },
        {
          phase: "Rozwiązanie: Appliance Mode ENABLE",
          status: "restored",
          message: "TGW pamięta punkt wejścia sesji i zmusza pakiet powrotny do powrotu przez TEN SAM ENI i TEN SAM firewall, na którym sesja została zainicjowana. Pełna integralność tablicy sesji!",
          affectedNodes: ["tgw-a", "fw1-a"]
        }
      ]
    }
  ]
};
const ARCHITECTURE_DATA_PL = ARCHITECTURE_DATA;
