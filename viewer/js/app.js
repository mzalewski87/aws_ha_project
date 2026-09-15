/**
 * Central Application Controller
 * Coordinates diagram, flow animations, DR simulations, presentations,
 * and bilingual localization (Polish & English).
 */

const UI_TRANSLATIONS = {
  pl: {
    tab_overview: "Przegląd",
    tab_flows: "Przepływy Ruchu",
    tab_scenarios: "Symulator Awarii",
    tab_presentation: "Prezentacja Klienta",
    search_placeholder: "Szukaj (np. HA2, TGW, EIP, IP)...",
    nav_level: "POZIOM:",
    nav_overview: "🌐 Overview",
    nav_ha: "🛡️ Klaster HA (Security)",
    nav_rega: "⚡ Region A (Frankfurt)",
    nav_regb: "🔄 Region B (Dublin DR)",
    nav_mgmt: "🔐 Panorama & SSM",
    pres_prev: "⬅ Poprzedni Slajd",
    pres_next: "Następny Slajd ➔",
    pres_counter: (curr, total) => `SLAJD ${curr} Z ${total}`,
    flow_step_ind: (curr, total) => `KROK ${curr} Z ${total}`,
    scen_step_ind: (curr, total, phase) => `FAZA ${curr} Z ${total}: ${phase.toUpperCase()}`,
    btn_prev: "Poprzedni",
    btn_next: "Następny",
    btn_pause: "Pauza",
    btn_resume: "Wznów",
    btn_back: "Cofnij",
    btn_next_phase: "Kolejna Faza ➔",
    btn_reset: "Resetuj",
    drawer_default_title: "Nazwa Komponentu",
    drawer_default_cat: "Kategoria",
    panel_overview_title: "Przegląd Architektury",
    panel_flows_title: "Animowane Przepływy Ruchu",
    panel_scenarios_title: "Symulator Awarii & HA",
    panel_pres_title: "Tryb Prezentacji Klienta",
    panel_overview_html: `
      <div style="font-size:12.5px; color:var(--text-muted); line-height:1.5;">
        <p style="margin-bottom:12px;">Projekt dostarcza wysoko dostępną bramę <strong>Palo Alto Networks GlobalProtect</strong> z centralną inspekcją <strong>AWS Transit Gateway</strong> w modelu Multi-Region.</p>
        <div class="callout-box" style="margin-bottom:12px;">
          <strong>Wskazówka Prezentacyjna:</strong> Kliknij dowolny element na schemacie, aby otworzyć szczegółowy panel techniczny z danymi o interfejsach, IP, tabelach tras i kodzie Terraform.
        </div>
        <h4 style="color:#fff; font-size:13px; margin:14px 0 8px 0;">Filary Projektu:</h4>
        <ul style="margin-left:18px; display:flex; flex-direction:column; gap:6px; font-size:12px;">
          <li><strong>Active/Passive VM-Series:</strong> Failover z wtyczką AWS HA (preemption wyłączone).</li>
          <li><strong>AWS Global Accelerator:</strong> Sub-30s failover Anycast całego regionu.</li>
          <li><strong>TGW Appliance Mode:</strong> Wymuszenie symetrii sesji międzystrefowych.</li>
          <li><strong>Pojedyncza Panorama:</strong> Zarządzanie przez prywatny TGW Peering.</li>
          <li><strong>Zero-Bastion:</strong> Pełny dostęp przez SSM Session Manager.</li>
        </ul>
      </div>
    `,
    panel_pres_html: `
      <div style="font-size:12.5px; color:var(--text-muted); line-height:1.5;">
        <p>Uruchomiono interaktywny tryb prezentacyjny. Użyj paska u dołu ekranu (lub klawiszy strzałek ➔ / ⬅), aby prowadzić klienta przez narrację projektu krok-po-kroku.</p>
        <div class="callout-box" style="margin-top:12px;">
          Aplikacja automatycznie przybliża kamerę (Auto-Focus) i podświetla odpowiednie komponenty architektury dla każdego slajdu.
        </div>
      </div>
    `
  },
  en: {
    tab_overview: "Overview",
    tab_flows: "Traffic Flows",
    tab_scenarios: "Failure Simulator",
    tab_presentation: "Client Presentation",
    search_placeholder: "Search (e.g. HA2, TGW, EIP, IP)...",
    nav_level: "LEVEL:",
    nav_overview: "🌐 Overview",
    nav_ha: "🛡️ HA Cluster (Security)",
    nav_rega: "⚡ Region A (Frankfurt)",
    nav_regb: "🔄 Region B (Dublin DR)",
    nav_mgmt: "🔐 Panorama & SSM",
    pres_prev: "⬅ Previous Slide",
    pres_next: "Next Slide ➔",
    pres_counter: (curr, total) => `SLIDE ${curr} OF ${total}`,
    flow_step_ind: (curr, total) => `STEP ${curr} OF ${total}`,
    scen_step_ind: (curr, total, phase) => `PHASE ${curr} OF ${total}: ${phase.toUpperCase()}`,
    btn_prev: "Previous",
    btn_next: "Next",
    btn_pause: "Pause",
    btn_resume: "Resume",
    btn_back: "Back",
    btn_next_phase: "Next Phase ➔",
    btn_reset: "Reset",
    drawer_default_title: "Component Name",
    drawer_default_cat: "Category",
    panel_overview_title: "Architecture Overview",
    panel_flows_title: "Animated Traffic Flows",
    panel_scenarios_title: "Failure & HA Simulator",
    panel_pres_title: "Client Presentation Mode",
    panel_overview_html: `
      <div style="font-size:12.5px; color:var(--text-muted); line-height:1.5;">
        <p style="margin-bottom:12px;">This project delivers an enterprise, resilient <strong>Palo Alto Networks GlobalProtect</strong> gateway with central <strong>AWS Transit Gateway</strong> inspection in a Multi-Region model.</p>
        <div class="callout-box" style="margin-bottom:12px;">
          <strong>Presentation Tip:</strong> Click any component on the diagram to open the technical deep-dive specification drawer with interface mapping, IP addressing, route tables, and Terraform details.
        </div>
        <h4 style="color:#fff; font-size:13px; margin:14px 0 8px 0;">Architecture Pillars:</h4>
        <ul style="margin-left:18px; display:flex; flex-direction:column; gap:6px; font-size:12px;">
          <li><strong>Active/Passive VM-Series:</strong> Automated failover via AWS HA Plugin (preemption disabled).</li>
          <li><strong>AWS Global Accelerator:</strong> Sub-30s Anycast regional failover bypassing DNS TTL.</li>
          <li><strong>TGW Appliance Mode:</strong> Stateful flow symmetry across Multi-AZ attachments.</li>
          <li><strong>Single Panorama:</strong> Centralized governance over encrypted private TGW Peering.</li>
          <li><strong>Zero-Bastion:</strong> Direct port forwarding via AWS SSM Session Manager.</li>
        </ul>
      </div>
    `,
    panel_pres_html: `
      <div style="font-size:12.5px; color:var(--text-muted); line-height:1.5;">
        <p>Interactive Client Walkthrough Mode is active. Use the bottom navigation bar (or keyboard arrow keys ➔ / ⬅) to guide clients through the project story step-by-step.</p>
        <div class="callout-box" style="margin-top:12px;">
          The camera automatically pans and zooms (Auto-Focus) while highlighting relevant components for each slide.
        </div>
      </div>
    `
  }
};

class AppController {
  constructor(defaultLang = "pl") {
    this.lang = defaultLang;
    this.data = (this.lang === "en") ? ARCHITECTURE_DATA_EN : ARCHITECTURE_DATA;

    this.currentMode = "overview"; // "overview" | "flows" | "scenarios" | "presentation"
    this.currentSlideIndex = 0;

    this.init();
  }

  init() {
    const svgEl = document.getElementById("architecture-svg");
    this.diagram = new ArchitectureDiagram(svgEl, this.data, (nodeId) => this.selectComponent(nodeId), this.lang);
    this.animator = new TrafficFlowAnimator(this.diagram, this.data.trafficFlows);
    this.simulator = new FailureSimulator(this.diagram, this.data.scenarios);

    this.setupDOM();
    this.applyLanguageUI();
    this.renderLeftPanel();
    this.setupSearch();

    // Default select
    this.selectComponent("fw-pair-a");
  }

  t(key) {
    const dict = UI_TRANSLATIONS[this.lang] || UI_TRANSLATIONS["pl"];
    return dict[key] || key;
  }

  setLanguage(lang) {
    if (this.lang === lang) return;
    this.lang = lang;
    this.data = (lang === "en") ? ARCHITECTURE_DATA_EN : ARCHITECTURE_DATA;

    // Update submodules
    this.diagram.data = this.data;
    this.diagram.lang = lang;
    this.animator.flows = this.data.trafficFlows;
    this.simulator.scenarios = this.data.scenarios;

    // Stop active playback
    this.animator.stop();
    this.simulator.resetAll();

    // Update UI
    this.applyLanguageUI();
    this.renderLeftPanel();
    this.diagram.render();

    // Refresh active component or slide
    if (this.diagram.selectedNodeId) {
      this.selectComponent(this.diagram.selectedNodeId);
    }
    if (this.currentMode === "presentation") {
      this.showSlide(this.currentSlideIndex);
    }
  }

  applyLanguageUI() {
    // Mode tabs text
    const tabs = {
      overview: this.t("tab_overview"),
      flows: this.t("tab_flows"),
      scenarios: this.t("tab_scenarios"),
      presentation: this.t("tab_presentation")
    };
    document.querySelectorAll(".mode-tab").forEach(tab => {
      const mode = tab.dataset.mode;
      const span = tab.querySelector("span");
      if (span && tabs[mode]) span.textContent = tabs[mode];
    });

    // Search placeholder
    const searchInput = document.getElementById("search-input");
    if (searchInput) searchInput.placeholder = this.t("search_placeholder");

    // Quick nav presets
    const navLevel = document.querySelector(".nav-label");
    if (navLevel) navLevel.textContent = this.t("nav_level");

    const navBtns = {
      overview: this.t("nav_overview"),
      "ha-cluster": this.t("nav_ha"),
      "region-a": this.t("nav_rega"),
      "region-b": this.t("nav_regb"),
      mgmt: this.t("nav_mgmt")
    };
    document.querySelectorAll(".nav-btn").forEach(btn => {
      const view = btn.dataset.view;
      if (navBtns[view]) btn.textContent = navBtns[view];
    });

    // Language switcher buttons in header
    document.querySelectorAll(".btn-lang").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.lang === this.lang);
    });

    // Presentation actions
    const btnPresPrev = document.querySelector(".presentation-actions button:first-child");
    const btnPresNext = document.querySelector(".presentation-actions button:last-child");
    if (btnPresPrev) btnPresPrev.textContent = this.t("pres_prev");
    if (btnPresNext) btnPresNext.textContent = this.t("pres_next");
  }

  setupDOM() {
    // Mode tabs
    document.querySelectorAll(".mode-tab").forEach(tab => {
      tab.addEventListener("click", () => {
        this.switchMode(tab.dataset.mode);
      });
    });

    // Language switcher
    document.querySelectorAll(".btn-lang").forEach(btn => {
      btn.addEventListener("click", () => {
        this.setLanguage(btn.dataset.lang);
      });
    });

    // Zoom Buttons
    document.getElementById("btn-zoom-in")?.addEventListener("click", () => this.diagram.zoom(1.2));
    document.getElementById("btn-zoom-out")?.addEventListener("click", () => this.diagram.zoom(0.8));
    document.getElementById("btn-zoom-reset")?.addEventListener("click", () => this.diagram.resetView());
    document.getElementById("btn-fullscreen")?.addEventListener("click", () => this.toggleFullscreen());

    // Drawer Close
    document.getElementById("btn-close-drawer")?.addEventListener("click", () => this.closeDrawer());

    // Keyboard navigation for presentation
    window.addEventListener("keydown", (e) => {
      if (this.currentMode !== "presentation") return;
      if (e.key === "ArrowRight" || e.key === "PageDown") {
        this.nextSlide();
      } else if (e.key === "ArrowLeft" || e.key === "PageUp") {
        this.prevSlide();
      }
    });
  }

  switchMode(mode) {
    this.currentMode = mode;
    document.querySelectorAll(".mode-tab").forEach(t => {
      t.classList.toggle("active", t.dataset.mode === mode);
    });

    // Stop active flow/scenario
    this.animator.stop();
    this.simulator.resetAll();

    // Presentation bar visibility
    const presBar = document.getElementById("presentation-bar");
    if (presBar) {
      presBar.classList.toggle("hidden", mode !== "presentation");
    }

    this.renderLeftPanel();

    if (mode === "presentation") {
      this.currentSlideIndex = 0;
      this.showSlide(0);
    } else {
      this.diagram.resetView();
    }
  }

  renderLeftPanel() {
    const titleEl = document.getElementById("panel-title");
    const contentEl = document.getElementById("panel-dynamic-content");
    if (!titleEl || !contentEl) return;

    if (this.currentMode === "overview") {
      titleEl.innerHTML = `
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18M9 21V9"/></svg>
        ${this.t("panel_overview_title")}
      `;
      contentEl.innerHTML = this.t("panel_overview_html");
    } else if (this.currentMode === "flows") {
      titleEl.innerHTML = `
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>
        ${this.t("panel_flows_title")}
      `;
      let html = `<div class="flow-list">`;
      this.data.trafficFlows.forEach((flow) => {
        html += `
          <div class="flow-card" data-flow-id="${flow.id}" onclick="window.app.selectFlow('${flow.id}')" style="--flow-color: ${flow.color}">
            <div class="flow-title">
              <span>${flow.name}</span>
              <span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:${flow.color};"></span>
            </div>
            <div class="flow-desc">${flow.description}</div>
          </div>
        `;
      });
      html += `</div><div id="flow-narration-placeholder"></div>`;
      contentEl.innerHTML = html;
    } else if (this.currentMode === "scenarios") {
      titleEl.innerHTML = `
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
        ${this.t("panel_scenarios_title")}
      `;
      let html = `<div class="flow-list">`;
      this.data.scenarios.forEach((scen) => {
        html += `
          <div class="scenario-card" data-scenario-id="${scen.id}" onclick="window.app.selectScenario('${scen.id}')">
            <div class="scenario-header">
              <span class="scenario-tag">${scen.tag}</span>
            </div>
            <div class="scenario-title">${scen.name}</div>
            <div class="scenario-desc">${scen.description}</div>
          </div>
        `;
      });
      html += `</div><div id="scenario-narration-placeholder"></div>`;
      contentEl.innerHTML = html;
    } else if (this.currentMode === "presentation") {
      titleEl.innerHTML = `
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg>
        ${this.t("panel_pres_title")}
      `;
      contentEl.innerHTML = this.t("panel_pres_html");
    }
  }

  selectFlow(flowId) {
    document.querySelectorAll(".flow-card").forEach(c => {
      c.classList.toggle("active", c.dataset.flowId === flowId);
    });
    this.animator.startFlow(flowId);
  }

  updateFlowNarration(flow, step, stepIdx) {
    const holder = document.getElementById("flow-narration-placeholder");
    if (!holder) return;

    holder.innerHTML = `
      <div class="narration-box">
        <div class="narration-step-indicator">${this.t("flow_step_ind")(stepIdx + 1, flow.steps.length)}</div>
        <div class="narration-title">${step.title}</div>
        <div class="narration-body">${step.text}</div>
        <div class="playback-controls">
          <button class="btn-playback" onclick="window.app.animator.prevStep()">${this.t("btn_prev")}</button>
          <button class="btn-playback primary" id="btn-flow-play" onclick="window.app.toggleFlowPlay()">
            ${this.animator.isPlaying ? this.t("btn_pause") : this.t("btn_resume")}
          </button>
          <button class="btn-playback" onclick="window.app.animator.nextStep()">${this.t("btn_next")}</button>
        </div>
      </div>
    `;
  }

  toggleFlowPlay() {
    const isPlaying = this.animator.togglePlay();
    const btn = document.getElementById("btn-flow-play");
    if (btn) btn.textContent = isPlaying ? this.t("btn_pause") : this.t("btn_resume");
  }

  selectScenario(scenId) {
    document.querySelectorAll(".scenario-card").forEach(c => {
      c.classList.toggle("active", c.dataset.scenarioId === scenId);
    });
    this.simulator.startScenario(scenId);
  }

  updateScenarioUI(scenario, step, stepIdx) {
    const holder = document.getElementById("scenario-narration-placeholder");
    if (!holder) return;

    let badgeColor = "#EF4444";
    if (step.status === "action") badgeColor = "#F59E0B";
    if (step.status === "restored" || step.status === "normal") badgeColor = "#10B981";

    holder.innerHTML = `
      <div class="narration-box" style="border-left: 3px solid ${badgeColor};">
        <div class="narration-step-indicator" style="color: ${badgeColor};">
          ${this.t("scen_step_ind")(stepIdx + 1, scenario.steps.length, step.phase)}
        </div>
        <div class="narration-body" style="color:#fff; margin-bottom:8px;">${step.message}</div>
        ${scenario.scriptCommand ? `
          <div style="font-family:var(--font-mono); font-size:10px; background:#000; padding:6px 8px; border-radius:4px; color:#38BDF8; margin-bottom:10px;">
            $ ${scenario.scriptCommand}
          </div>
        ` : ''}
        <div class="playback-controls">
          <button class="btn-playback" onclick="window.app.simulator.prevStep()">${this.t("btn_back")}</button>
          <button class="btn-playback primary" onclick="window.app.simulator.nextStep()">${this.t("btn_next_phase")}</button>
          <button class="btn-playback" onclick="window.app.simulator.resetAll(); window.app.selectScenario('${scenario.id}')">${this.t("btn_reset")}</button>
        </div>
      </div>
    `;
  }

  showSlide(index) {
    const slides = this.data.presentationSlides;
    if (index < 0 || index >= slides.length) return;
    this.currentSlideIndex = index;
    const slide = slides[index];

    const titleEl = document.getElementById("pres-slide-title");
    const countEl = document.getElementById("pres-slide-counter");
    const contentEl = document.getElementById("pres-slide-content");

    if (titleEl) titleEl.textContent = slide.title;
    if (countEl) countEl.textContent = this.t("pres_counter")(index + 1, slides.length);
    if (contentEl) contentEl.innerHTML = slide.content;

    // Focus camera
    this.diagram.focusOn(slide.targetFocus, slide.zoomLevel || 1.3);
  }

  nextSlide() {
    this.showSlide(this.currentSlideIndex + 1);
  }

  prevSlide() {
    this.showSlide(this.currentSlideIndex - 1);
  }

  selectComponent(componentId) {
    const comp = this.data.components[componentId];
    if (!comp) return;

    this.diagram.highlightNode(componentId);

    // Open right drawer
    const drawer = document.getElementById("component-drawer");
    const titleEl = document.getElementById("drawer-title");
    const catEl = document.getElementById("drawer-cat");
    const iconEl = document.getElementById("drawer-icon-holder");
    const summaryEl = document.getElementById("drawer-summary");
    const tableEl = document.getElementById("drawer-specs-table");

    if (titleEl) titleEl.textContent = comp.name;
    if (catEl) catEl.textContent = comp.category;
    if (iconEl) iconEl.innerHTML = ICONS[comp.icon] || ICONS["aws-logo"];
    if (summaryEl) summaryEl.textContent = comp.summary;

    if (tableEl && comp.details) {
      let rowsHtml = "";
      for (const [k, v] of Object.entries(comp.details)) {
        rowsHtml += `
          <tr>
            <th>${k}</th>
            <td>${v}</td>
          </tr>
        `;
      }
      tableEl.innerHTML = rowsHtml;
    }

    drawer?.classList.add("open");
  }

  closeDrawer() {
    document.getElementById("component-drawer")?.classList.remove("open");
    this.diagram.clearHighlights();
  }

  toggleSecurityVpc() {
    this.diagram.toggleSecurityVpc();
  }

  toggleRegionB() {
    this.diagram.toggleRegionB();
  }

  setViewPreset(preset) {
    document.querySelectorAll(".nav-btn").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.view === preset);
    });

    if (preset === "overview") {
      this.diagram.securityVpcExpanded = false;
      this.diagram.regionBCollapsed = true;
      this.diagram.render();
      this.diagram.resetView();
    } else if (preset === "ha-cluster") {
      this.diagram.securityVpcExpanded = true;
      this.diagram.render();
      this.diagram.focusOn("fw-pair-a", 1.3);
      this.selectComponent("fw-pair-a");
    } else if (preset === "region-a") {
      this.diagram.focusOn("region-a", 1.05);
    } else if (preset === "region-b") {
      this.diagram.regionBCollapsed = false;
      this.diagram.render();
      this.diagram.focusOn("region-b", 1.05);
    } else if (preset === "mgmt") {
      this.diagram.focusOn("panorama", 1.35);
      this.selectComponent("panorama");
    }
  }

  toggleFullscreen() {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen().catch(() => {});
    } else {
      document.exitFullscreen().catch(() => {});
    }
  }

  setupSearch() {
    const searchInput = document.getElementById("search-input");
    if (!searchInput) return;

    searchInput.addEventListener("input", (e) => {
      const q = e.target.value.toLowerCase().trim();
      if (!q) {
        this.diagram.clearHighlights();
        return;
      }

      // Search across components in active language
      for (const [id, comp] of Object.entries(this.data.components)) {
        if (
          comp.name.toLowerCase().includes(q) ||
          comp.summary.toLowerCase().includes(q) ||
          JSON.stringify(comp.details).toLowerCase().includes(q)
        ) {
          this.diagram.focusOn(id, 1.4);
          this.selectComponent(id);
          break;
        }
      }
    });
  }
}

// Global bootstrap on load
window.addEventListener("DOMContentLoaded", () => {
  // Read optional lang query param ?lang=en or detect path
  const urlParams = new URLSearchParams(window.location.search);
  const isEnFile = window.location.pathname.endsWith("index_en.html");
  const initialLang = urlParams.get("lang") || (isEnFile ? "en" : "pl");

  window.app = new AppController(initialLang);
});
