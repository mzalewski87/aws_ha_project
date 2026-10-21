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
    version: "v2.0",
    panosVersion: "12.2.4 (min. ścieżka B) / 11.1.15 (domyślnie ścieżka A)",
    panoramaVersion: "11.1.15 (tylko ścieżka A)",
    keyConcepts: [
      "Active/Passive VM-Series HA with PAN-OS AWS HA Plugin",
      "Multi-Region Resilience via AWS Global Accelerator Anycast",
      "Native GlobalProtect Gateway Failover (No external LB)",
      "Transit Gateway with Appliance Mode (Cross-AZ flow symmetry)",
      "Central Panorama with Zero-Bastion SSM Session Manager",
      "Resilient Active Directory Multi-Master Forest & LDAP Auth"
    ]
  },

  // Węzły schematu bez własnego wpisu otwierają ten wskazany.
  componentAliases: {
    "fw1-a": "fw-pair-a",
    "fw2-a": "fw-pair-a",
    "fw1-b": "fw-pair-b",
    "untrust-b": "globalprotect-service",
    "apache-a": "spoke1-app",
    "dc-a": "spoke2-dc"
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
          <strong>Dlaczego to unikalne?</strong> Bez przełączania DNS (TTL u ISP). Klienci zachowują te same dwa adresy anycast; Global Accelerator wyłącza region po <strong>jednym</strong> nieudanym teście (co 10 s) i przenosi jego klientów do drugiego regionu. W regionie para HA przełącza się w ~1–8 s.
        </div>
      `
    },
    {
      id: "mgmt_paths",
      title: "2. Dwie Ścieżki Zarządzania: Panorama (A) lub Strata Cloud Manager (B) — ADR D11",
      targetFocus: "global",
      zoomLevel: 1.0,
      mgmtPath: "B",
      content: `
        <p>Jeden kod, wybór przez <code>management_mode</code>. Wszystko poza zarządzaniem (VPC, TGW, para HA, GP, DC/PKI, Guacamole) jest wspólne. Porównaj przełącznikiem <strong>ŚCIEŻKA ZARZĄDZANIA</strong> na schemacie lub w lewym panelu.</p>
        <table class="slide-table">
          <tr><th></th><th>Ścieżka A — Panorama</th><th>Ścieżka B — Strata Cloud Manager</th></tr>
          <tr><td>Menedżer</td><td>Panorama EC2 + 2 TB EBS na logi</td><td>tenant SCM (SaaS), bez EC2</td></tr>
          <tr><td>Bootstrap</td><td><code>panorama-server=&lt;ip&gt;</code> + vm-auth-key</td><td><code>panorama-server=cloud</code> + PIN rejestracyjny</td></tr>
          <tr><td>Konfiguracja</td><td>template stack + device group</td><td>jeden folder dla obu regionów; zmienne per-urządzenie</td></tr>
          <tr><td>HA / routing</td><td><code>configure-ha.sh</code> (SSH) · klasyczny VR</td><td>z SCM (<code>scm-ha.sh</code>) · logical router ARE</td></tr>
          <tr><td>PAN-OS</td><td>przypięty, Panorama ≥ FW (domyślnie 11.1.15)</td><td>min. 12.2.4 (obraz 12.2.3 ➔ upgrade w miejscu)</td></tr>
        </table>
      `
    },
    {
      id: "ha_choice",
      title: "3. Model HA: Active/Passive zamiast GWLB (ADR D1)",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.35,
      content: `
        <h4>Decyzja Architektoniczna ADR D1</h4>
        <p>W każdym regionie wdrożono <strong>parę Active/Passive VM-Series</strong> z dedykowanymi łączami HA1 (sterowanie/heartbeat) i HA2 (synchronizacja sesji); po stronie AWS przełączeniem steruje wtyczka PAN-OS AWS HA.</p>
        <p><strong>Dlaczego NIE AWS Gateway Load Balancer (GWLB)?</strong></p>
        <ul>
          <li>GWLB to transparentny mechanizm „bump-in-the-wire” (GENEVE) bez adresowalnego publicznego IP per firewall.</li>
          <li>GlobalProtect terminujący ruch VPN klientów na publicznym IP wymaga stabilnego, adresowalnego punktu wejścia.</li>
          <li>Active/Passive z pływającym adresem wtórnym (z EIP) daje jeden stały publiczny punkt wejścia na region.</li>
        </ul>
      `
    },
    {
      id: "eni_quirks",
      title: "4. Anatomia Interfejsów ENI i Wymogi AWS",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.5,
      content: `
        <h4>Sztywne wymagania platformowe PAN-OS na AWS</h4>
        <ul>
          <li><code>device_index=0</code> (eth0) ➔ <strong>Management (HA1)</strong>: sterowanie, ping ICMP i porty TCP 28769/28260.</li>
          <li><code>device_index=1</code> (eth1) ➔ <strong>HA2 (Data Link)</strong>: wymóg AWS – <code>ethernet1/1</code> MUSI być HA2.</li>
          <li><code>device_index=2</code> (eth2) ➔ <strong>Trust (ethernet1/2)</strong>: Transit Gateway (source/dest check = off), pływający <code>10.10.20.100</code>.</li>
          <li><code>device_index=3</code> (eth3) ➔ <strong>Untrust (ethernet1/3)</strong>: ruch publiczny, pływający <code>10.10.10.100</code> (z EIP; GP na <strong>loopback.1</strong>).</li>
        </ul>
        <p>Pływający <code>.100</code> musi być adresem <strong>wtórnym</strong> — moduł podaje uporządkowaną listę IP.</p>
      `
    },
    {
      id: "ha_failover",
      title: "5. Failover HA: Co Naprawdę Się Przenosi (pomiary)",
      targetFocus: "fw-pair-a",
      zoomLevel: 1.3,
      content: `
        <h4>Wtyczka AWS HA, tryb secondary-IP (PAN-OS 12.2.4, plugin 6.2.1)</h4>
        <ul>
          <li>Nowy aktywny FW wywołuje <code>AssignPrivateIpAddresses</code>: <strong>untrust .100</strong> (EIP jest z nim skojarzony, więc idzie za nim) i <strong>trust .100</strong> przechodzą na jego ENI.</li>
          <li><code>ReplaceRoute</code> w <strong>obu tablicach tras TGW-attachment</strong>: <code>0.0.0.0/0</code> ➔ jego trust ENI.</li>
          <li>Wtyczka przepisuje tylko trasy wskazujące ENI, z których przenosi IP — dlatego trust ENI też ma pływający IP.</li>
        </ul>
        <div class="callout-box"><strong>Zmierzone:</strong> przejęcie 0,7–7,7 s; portal GP niedostępny ~5 s na przełączenie; CloudTrail ~6 s po suspend. Preemption wyłączone.</div>
      `
    },
    {
      id: "tgw_appliance",
      title: "6. Transit Gateway & Appliance Mode (ADR D5)",
      targetFocus: "tgw-a",
      zoomLevel: 1.45,
      content: `
        <h4>Centralny Hub i Symetria Stanowa</h4>
        <p>Wszystkie VPC w regionie (Security, Mgmt, Spoke 1, Spoke 2) są dołączone do AWS Transit Gateway.</p>
        <div class="callout-box warning">
          <strong>Kluczowa flaga:</strong> <code>appliance_mode_support = enable</code> na attachmentcie Security VPC.
        </div>
        <p>Bez Appliance Mode ruch powrotny w architekturze Multi-AZ może wrócić przez firewall w innej strefie, który zrzuci sesję. Appliance Mode wymusza pełną symetrię przepływu.</p>
      `
    },
    {
      id: "mgmt_panorama",
      title: "7. Ścieżka A: Panorama & Zero-Bastion (ADR D6, D8)",
      targetFocus: "panorama",
      zoomLevel: 1.35,
      mgmtPath: "A",
      content: `
        <h4>Pojedyncza Panorama dla Wszystkich Regionów</h4>
        <p>Jedna instancja Panorama (<code>m5.4xlarge</code>, dysk logów 2 TB) w Regionie A zarządza obiema parami firewalli przez prywatny TGW Peering (template stack + device group, osobny workspace <code>panos</code>).</p>
        <h4>Bezpieczeństwo: Zero Bastion</h4>
        <p>Brak publicznych portów zarządzania. Terraform, XML API i konsola przez <strong>AWS SSM Session Manager Port Forwarding</strong> za pośrednictwem SSM Jump Hosta.</p>
      `
    },
    {
      id: "mgmt_scm",
      title: "8. Ścieżka B: Strata Cloud Manager w Praktyce",
      targetFocus: "scm",
      zoomLevel: 1.25,
      mgmtPath: "B",
      content: `
        <ul>
          <li>init-cfg: <code>panorama-server=cloud</code> + PIN rejestracyjny + <code>advance-routing:enable</code>; brak EC2 Panoramy i aktywacji OTP.</li>
          <li><strong>Jeden folder SCM</strong> (<code>phase2-scm-config/</code>) trzyma <strong>pary obu regionów</strong>; wartości regionu to <strong>zmienne per-urządzenie</strong>.</li>
          <li><strong>HA konfigurowane z SCM</strong> (<code>scm-ha.sh</code>); routing to <strong>logical router ARE</strong>.</li>
          <li><strong>PAN-OS min. 12.2.4</strong>: najnowszy obraz Marketplace to 12.2.3, więc <code>scm-upgrade.sh</code> robi upgrade w miejscu przez SCM.</li>
          <li>Portal/brama GP nie mają obiektu w API SCM: budowane lokalnie na <strong>każdym</strong> FW (<code>scm-gp-local.sh</code>).</li>
        </ul>
      `
    },
    {
      id: "multi_region_ga",
      title: "9. Odporność Multi-Region: Global Accelerator (ADR D3)",
      targetFocus: "global-accelerator",
      zoomLevel: 1.25,
      content: `
        <h4>Najbliższy zdrowy region — nie podział, nie priorytet</h4>
        <ul>
          <li>Dwa statyczne adresy anycast przed portalem (TCP 443, UDP 4501, TCP 80 ➔ ALB z przekierowaniem).</li>
          <li>Obie grupy endpointów mają <strong>traffic dial 100%</strong>: każdy klient trafia do <strong>najbliższego zdrowego</strong> regionu. Klienci w Polsce ➔ eu-central-1 (Region A).</li>
          <li>Health check TCP 443 co <strong>10 s</strong> (minimum GA), <strong>próg 1</strong>: jeden nieudany test przenosi klientów regionu do drugiego (~10 s detekcji).</li>
        </ul>
        <div class="callout-box">Przy domyślnym progu 3 awaria regionu dała <strong>73 s</strong> niedostępności portalu w teście panelu — stąd próg 1. Cena: jeden zgubiony test też przenosi ruch.</div>
      `
    },
    {
      id: "gp_native_failover",
      title: "10. Natywny Wybór Bram GlobalProtect (ADR D4)",
      targetFocus: "global",
      zoomLevel: 1.1,
      content: `
        <h4>Brak zewnętrznego load balancera przed bramami VPN</h4>
        <p>Każdy portal (wszystkie cztery FW) podaje tę samą listę bram:</p>
        <ul>
          <li><code>gw-a.&lt;zone&gt;</code> — EIP Regionu A, pula 10.10.200.0/24</li>
          <li><code>gw-b.&lt;zone&gt;</code> — EIP Regionu B, pula 10.20.200.0/24</li>
        </ul>
        <p>Agent GP mierzy czas odpowiedzi SSL, łączy się z najlepszą bramą i sam wykonuje failover (w laboratorium ścieżki B obie mają priorytet 1).</p>
      `
    },
    {
      id: "ad_replication",
      title: "11. Tożsamość: Zreplikowane AD DS + Dwupoziomowe PKI AD CS",
      targetFocus: "dc-a",
      zoomLevel: 1.2,
      content: `
        <ul>
          <li>Podstawowy DC <code>10.13.0.10</code> (<code>panw.labs</code>) w Regionie A, <strong>replika</strong> <code>10.23.0.10</code> w Regionie B; replikacja przez TGW peering (0 błędów w obie strony).</li>
          <li>Profile LDAP zawierają oba DC; klienci gw-b dostają replikę jako główny DNS.</li>
          <li><strong>PKI AD CS</strong>: samodzielny root CA (<code>10.13.0.20</code>) + enterprise issuing CA (<code>10.13.0.21</code>), autoenrolment certyfikatów maszyn dla GP pre-logon.</li>
        </ul>
      `
    },
    {
      id: "app_path",
      title: "12. Strona Testowa: CloudFront + WAF ➔ NLB ➔ Firewall ➔ Apache",
      targetFocus: "cloudfront",
      zoomLevel: 1.3,
      content: `
        <ol>
          <li><strong>CloudFront</strong> (certyfikat ACM w us-east-1) za <strong>WAF w zakresie CLOUDFRONT</strong>: <code>https://website.&lt;zone&gt;</code>.</li>
          <li>Origin to <strong>NLB aplikacji</strong>; jego security group wpuszcza <strong>tylko prefiksy origin-facing CloudFront</strong> — nie da się ominąć CloudFront i WAF.</li>
          <li>NLB celuje w pływający VIP <code>10.10.10.100:80</code> aktywnego firewalla.</li>
          <li>Firewall robi <strong>DNAT</strong> do Apache (<code>10.12.0.10</code>) i SNAT na swój trust IP.</li>
        </ol>
      `
    },
    {
      id: "panel_waf",
      title: "13. Panel Admina/Testów, AWS WAF i Guacamole (laboratorium B)",
      targetFocus: "admin-panel",
      zoomLevel: 1.3,
      mgmtPath: "B",
      content: `
        <ul>
          <li><strong>Panel</strong> (<code>https://panel.&lt;zone&gt;</code>): 2 hosty w 2 AZ w mgmt VPC za własnym ALB, poza ścieżką firewalli. Logowanie AD, topologia obu regionów na żywo z health GA, animowana symulacja polityki (<code>test security-policy-match</code>), testy awarii (HA, twardy, <strong>awaria regionu</strong>) z pomiarem czasów; historia w DynamoDB.</li>
          <li><strong>AWS WAF</strong> na ALB panelu i na CloudFront: geo allow-list (lab: Polska), limit per IP, reguły zarządzane AWS. GP celowo poza WAF.</li>
          <li><strong>Guacamole</strong> (obie ścieżki): RDP w przeglądarce przez ALB + obowiązkowe TOTP; RDP do DC przechodzi przez firewalle.</li>
        </ul>
      `
    },
    {
      id: "threat",
      title: "14. Advanced IP Defense i Frontier Virtual Patching (ścieżka B)",
      targetFocus: "threat-prevention",
      zoomLevel: 1.4,
      mgmtPath: "B",
      content: `
        <ul>
          <li><strong>Advanced IP Defense</strong> (<code>ip_defense_mode = off | alert | block</code>): predefiniowane listy IP PANW (<code>panw-aipd-*</code>, Tor, bullet-proof, high-risk) na górze polityki; <code>alert</code> = allow + log, <code>block</code> = deny wychodzący i przychodzący.</li>
          <li><strong>Frontier Virtual Patching</strong>: ustawienie profilu Vulnerability Protection; wymaga Advanced Threat Prevention Plus i <strong>PAN-OS 12.2.4+</strong>. Sygnatur nie da się wywołać na żądanie.</li>
        </ul>
      `
    },
    {
      id: "summary_takeaways",
      title: "15. Podsumowanie Wartości dla Klienta",
      targetFocus: "global",
      zoomLevel: 1.0,
      content: `
        <h4>Kluczowe Korzyści Biznesowo-Architektoniczne</h4>
        <div class="benefits-grid">
          <div class="benefit-card">
            <div class="badge">~5 s / ~10 s</div>
            <h5>Zmierzona Odporność</h5>
            <p>~5 s przerwy portalu na przełączenie HA; martwy region wykryty po jednym teście 10 s, klienci przeniesieni.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">Zero Bastion + WAF</div>
            <h5>Bezpieczny Dostęp</h5>
            <p>Brak publicznych portów zarządzania; SSM, Guacamole z TOTP, panel i strona za WAF.</p>
          </div>
          <div class="benefit-card">
            <div class="badge">A lub B</div>
            <h5>Jeden Kod, Dwa Menedżery</h5>
            <p>Panorama lub Strata Cloud Manager — ta sama architektura AWS, w całości w Terraform.</p>
          </div>
        </div>
      `
    }
  ],


  // Detailed technical components for the Drill-Down panel
  components: {
    "scm": {
      id: "scm",
      name: "Strata Cloud Manager (Ścieżka B)",
      category: "Zarządzanie w chmurze Palo Alto Networks",
      icon: "panw-scm",
      mgmtPath: "B",
      summary: "Płaszczyzna zarządzania w chmurze zastępująca Panoramę w ścieżce B. Jeden folder SCM trzyma pary HA obu regionów; wartości regionu to zmienne per-urządzenie. Bez EC2 Panoramy i bez OTP.",
      details: {
        "Wybór": "management_mode = \"scm\" (ADR D11)",
        "Bootstrap (init-cfg)": "panorama-server=cloud + PIN rejestracyjny; plugin-op-commands=advance-routing:enable",
        "Folder": "AWS-HA-Transit — pary Regionu A i B (4 FW)",
        "Wartości per-urządzenie": "scm_variable z device = (pływający IP, next-hopy, brama)",
        "Workspace": "phase2-scm-config/ (provider scm); scm-onboard-fw.sh; scm-push.sh",
        "HA": "Z SCM (/ha-configurations, scm-ha.sh) — provider nie ma zasobu HA",
        "Routing": "Advanced Routing Engine: scm_logical_router",
        "PAN-OS": "Min. 12.2.4; obraz 12.2.3 ➔ upgrade w miejscu (scm-upgrade.sh)",
        "GlobalProtect": "Brak obiektu w API SCM — lokalny XML na KAŻDYM FW (scm-gp-local.sh)",
        "Logi": "Strata Logging Service"
      }
    },
    "admin-panel": {
      id: "admin-panel",
      name: "Panel Admina / Testów (Ścieżka B)",
      category: "Konsola operacyjna",
      icon: "panel-dashboard",
      mgmtPath: "B",
      summary: "Konsola https://panel.<zone> na własnym ALB (+ WAF), 2 hosty w 2 AZ w mgmt VPC — poza ścieżką firewalli, które monitoruje.",
      details: {
        "Hosting": "2 × t3.small w 2 AZ (mgmt VPC 10.11/16), ALB (ACM) + WAF REGIONAL",
        "Logowanie": "AD (NTLM do DC przez firewalle) + grupy panel-admins / panel-operators",
        "Topologia": "Oba regiony na żywo: role HA, stan EC2, sync, gdzie EIP i trasy, health endpointów GA",
        "Symulacja polityki": "test security-policy-match na AKTYWNYM FW, animowany przebieg reguł",
        "Testy awarii": "Sync · HA failover (~47 s) · twardy (~7,5 min) · awaria regionu (~8,5 min) · Align · Recover",
        "Zmierzone": "Przejęcie 0,7–7,7 s; portal niedostępny ~5 s na przełączenie",
        "Historia": "DynamoDB <prefix>-panel-runs; jeden test naraz (lease DynamoDB)",
        "Terraform": "modules/panel, panel.tf (tylko ścieżka B)"
      }
    },
    "waf": {
      id: "waf",
      name: "AWS WAF (dwa web ACL)",
      category: "AWS Edge / Bezpieczeństwo WWW",
      icon: "aws-waf",
      summary: "AWS WAF przed dwoma publicznymi endpointami WWW: stroną testową w CloudFront i (ścieżka B) ALB panelu. GlobalProtect celowo poza WAF.",
      details: {
        "Web ACL 1": "Zakres CLOUDFRONT (us-east-1) na dystrybucji strony",
        "Web ACL 2": "Zakres REGIONAL (Region A) na ALB panelu",
        "Reguła 1": "geo-allow-only: tylko kraje z waf_allowed_countries (lab: [\"PL\"])",
        "Reguła 2": "Limit per IP 1000 / 5 min",
        "Reguła 3": "Grupy zarządzane AWS: reputacja IP, anonimowe IP, known bad inputs, core rule set, SQLi",
        "Poza WAF": "GlobalProtect (L4 przez GA / EIP bram)",
        "Terraform": "modules/waf, waf.tf"
      }
    },
    "guacamole": {
      id: "guacamole",
      name: "Apache Guacamole — RDP w przeglądarce (obie ścieżki)",
      category: "Dostęp administracyjny (ADR D12)",
      icon: "guacamole-rdp",
      summary: "Host Guacamole w mgmt VPC za publicznym ALB. RDP do DC przechodzi przez TGW i firewalle (inspekcja + logi); żaden port RDP nie jest wystawiony.",
      details: {
        "URL": "https://rdp.<zone>/guacamole/",
        "Uwierzytelnianie": "Hasło admina w Secrets Manager; brak guacadmin; TOTP obowiązkowe",
        "Konta AD (opcja)": "guac_ldap_enabled: logują się członkowie grupy AD guacusers (LDAP do DC, reguła guacamole-ldap-to-dc); TOTP nadal obowiązkowe",
        "Ścieżka": "Guacamole ➔ TGW ➔ firewalle (reguła guacamole-rdp-to-dc, trust➔trust ms-rdp) ➔ DC",
        "Terraform": "modules/guacamole, guacamole.tf"
      }
    },
    "pki": {
      id: "pki",
      name: "Dwupoziomowe PKI AD CS",
      category: "Tożsamość i certyfikaty",
      icon: "pki-cert",
      summary: "Samodzielny root CA i enterprise issuing CA w spoke 2, z autoenrolmentem certyfikatów maszyn dla GP pre-logon.",
      details: {
        "Root CA": "10.13.0.20 — samodzielny, poza domeną",
        "Issuing CA": "10.13.0.21 — enterprise CA w domenie",
        "Autoenrolment": "Certyfikaty maszyn przez GPO (setup-machine-autoenroll.sh)",
        "Znana luka": "Publikacja CRL roota do AD nie działa (ERROR_DS_REFERRAL)",
        "Terraform": "modules/pki, scripts/setup-pki.sh"
      }
    },
    "threat-prevention": {
      id: "threat-prevention",
      name: "Advanced IP Defense i Frontier Virtual Patching",
      category: "Threat Prevention Palo Alto Networks",
      icon: "panw-threat",
      mgmtPath: "B",
      summary: "Usługi bezpieczeństwa ścieżki B: predefiniowane listy reputacji IP PANW na górze polityki oraz Frontier Virtual Patching w profilu Vulnerability Protection.",
      details: {
        "Advanced IP Defense": "ip_defense_mode = off | alert | block",
        "Listy": "panw-aipd-*, panw-torexit-ip-list, panw-bulletproof-ip-list, panw-highrisk-ip-list",
        "alert / block": "allow + log / deny wychodzący + przychodzący",
        "Frontier Virtual Patching": "Wymaga Advanced Threat Prevention Plus + PAN-OS 12.2.4+",
        "Testy": "Sygnatur pre-disclosure nie da się wywołać na żądanie"
      }
    },
    "dc-b": {
      id: "dc-b",
      name: "Windows DC — Replika (Region B)",
      category: "Tożsamość i katalog",
      icon: "aws-directory-service",
      summary: "Dodatkowy kontroler domeny panw.labs w Regionie B — uwierzytelnianie i DNS działają po utracie Regionu A.",
      details: {
        "Prywatny IP": "10.23.0.10",
        "Replikacja": "AD multi-master przez TGW peering (bezpośrednio, nie przez firewalle); 0 błędów",
        "Użycie": "LDAP firewalli Regionu B; główny DNS klientów gw-b"
      }
    },
    "global-accelerator": {
      id: "global-accelerator",
      name: "AWS Global Accelerator",
      category: "AWS Edge / Routing",
      icon: "aws-global-accelerator",
      summary: "Dwa statyczne adresy anycast przed portalem GP. Każdy klient trafia do NAJBLIŻSZEGO ZDROWEGO regionu; gdy region nie przejdzie health checku, wszyscy jego klienci przechodzą do drugiego.",
      details: {
        "Typ usługi": "AWS Global Accelerator (Global Plane, zarządzenie z us-west-2)",
        "Adresacja": "2 statyczne adresy Anycast IP (niezmienne)",
        "Listenery": "TCP 443 (SSL Portal/VPN) + UDP 4501 (IPSec Portal fallback) + opcjonalnie TCP 80 (Redirect ALB)",
        "Endpoint Groups": "Region A (EIP eu-central-1) + Region B (EIP eu-west-1), OBA z traffic dial 100%",
        "Semantyka ruchu": "Nie podział 50/50 i bez priorytetu: najbliższy zdrowy region (Polska ➔ Region A)",
        "Health Checks": "TCP 443, interwał 10 s (minimum GA), próg 1 (health_check_threshold)",
        "Czas przełączenia (Failover)": "Jeden nieudany test wyłącza region (~10 s detekcji); próg 3 dał zmierzone 73 s przerwy portalu",
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
        "Amazon Side ASN": "64512 (domyślna wartość modułu w obu regionach)",
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
        "Wersja PAN-OS": "Ścieżka B: min. 12.2.4 (obraz 12.2.3 ➔ upgrade przez SCM). Ścieżka A: przypięta (domyślnie 11.1.15)",
        "Co się przenosi": "untrust .100 (z EIP) + trust .100 (AssignPrivateIpAddresses); obie tablice tras TGW-attachment (ReplaceRoute)",
        "Zmierzone": "Przejęcie 0,7–7,7 s; przerwa portalu GP ~5 s",
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
        "Wersja PAN-OS": "Ta sama co Region A (ścieżka B: 12.2.4)",
        "Zarządzanie (ścieżka B)": "Ten sam folder SCM co Region A; zmienne per-urządzenie; HA z SCM",
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
      mgmtPath: "A",
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
      name: "5A. Management Plane — Ścieżka A (Panorama ➔ TGW Peering ➔ Region B)",
      color: "#F59E0B",
      mgmtPath: "A",
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
          nodes: ["tgw-b", "fw1-b"]
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
          message: "1. AssignPrivateIpAddresses: untrust .100 i trust .100 przechodzą na ENI FW2 — EIP jest skojarzony z untrust .100, więc idzie za nim.<br/>2. ReplaceRoute: obie tablice tras TGW-attachment kierują 0.0.0.0/0 na trust ENI FW2.<br/>CloudTrail: ~6 s po suspend.",
          affectedNodes: ["untrust-a", "trust-a", "eip-a"]
        },
        {
          phase: "Przywrócenie Ruchu",
          status: "restored",
          message: "Zmierzone: przejęcie 0,7–7,7 s, portal GP niedostępny ~5 s. FW1 wraca jako Passive (preemption wyłączone); 'Align the pair' w panelu przywraca role.",
          affectedNodes: ["fw2-a"]
        }
      ]
    },
    {
      id: "scenario-region-outage",
      name: "Scenariusz 2: Awaria Całego Regionu (Global Accelerator)",
      tag: "Multi-Region",
      description: "Region A gaśnie (test 'Region outage' w panelu zatrzymuje oba FW). GA wyłącza go po JEDNYM nieudanym teście co 10 s i przenosi jego klientów do Regionu B.",
      scriptCommand: "panel ➔ Failover tests ➔ Region outage   (lub: bash scripts/failover-test.sh region a down)",
      steps: [
        {
          phase: "Normalnie: najbliższy zdrowy",
          status: "normal",
          message: "Obie grupy endpointów mają traffic dial 100%. Każdy klient trafia do najbliższego zdrowego regionu: Polska ➔ Region A (eu-central-1), bliżej Irlandii ➔ Region B. Bez podziału i bez priorytetu.",
          affectedNodes: ["global-accelerator"],
          badges: { "global-accelerator": ["NEAREST HEALTHY", "#10B981"] }
        },
        {
          phase: "Awaria Regionu A",
          status: "failure",
          message: "Oba firewalle Regionu A stają. Portal i gw-a na EIP Regionu A przestają odpowiadać.",
          affectedNodes: ["region-a", "fw1-a", "fw2-a"],
          badges: { "global-accelerator": ["CHECKING…", "#F59E0B"] }
        },
        {
          phase: "Health check GA nie przechodzi",
          status: "action",
          message: "GA testuje TCP 443 na EIP każdego regionu co 10 s (minimum GA). Próg 1: pierwszy nieudany test oznacza Region A jako unhealthy — ~10 s detekcji. (Przy domyślnym progu 3 zmierzono 73 s przerwy portalu.)",
          affectedNodes: ["global-accelerator"],
          badges: { "global-accelerator": ["A UNHEALTHY", "#EF4444"] }
        },
        {
          phase: "Klienci przechodzą do Regionu B",
          status: "action",
          message: "GA kieruje klientów Regionu A — np. wszystkich z Polski — do Regionu B przez te same dwa adresy anycast. Bez zmian DNS. Cena progu 1: jeden zgubiony test też przenosi ruch.",
          affectedNodes: ["global-accelerator", "untrust-b"],
          badges: { "global-accelerator": ["ALL ➔ REGION B", "#00F0FF"] }
        },
        {
          phase: "Wybór bramy GP",
          status: "action",
          message: "Portal (teraz z Regionu B) podaje gw-a i gw-b; agenci, którzy stracili gw-a, wybierają gw-b według czasu odpowiedzi SSL.",
          affectedNodes: ["gp-client", "fw1-b"],
          badges: { "global-accelerator": ["ALL ➔ REGION B", "#00F0FF"] }
        },
        {
          phase: "LDAP / DNS na replice DC",
          status: "restored",
          message: "Firewalle Regionu B uwierzytelniają przez replikę DC 10.23.0.10 (replikacja AD przez TGW peering); klienci gw-b już używają jej jako głównego DNS.",
          affectedNodes: ["fw1-b", "dc-b"],
          badges: { "global-accelerator": ["ALL ➔ REGION B", "#00F0FF"] }
        },
        {
          phase: "Powrót",
          status: "normal",
          message: "Gdy Region A znów przejdzie health check, jego bliscy klienci wracają do niego (najbliższy zdrowy). Test w panelu czeka na czystą parę active/passive i przywraca role.",
          affectedNodes: ["global-accelerator"],
          badges: { "global-accelerator": ["A HEALTHY AGAIN", "#10B981"] }
        }
      ]
    },
    {
      id: "scenario-panorama-outage",
      name: "Scenariusz 3A: Awaria Panoramy (Ścieżka A)",
      tag: "Management Plane · A",
      mgmtPath: "A",
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
      name: "Scenariusz 5: Rola Transit Gateway Appliance Mode",
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
