/**
 * Disaster Recovery & Failure Scenarios Engine
 * Interactively models component failures, AWS API failover actions, and traffic recovery.
 *
 * Scenario data can carry:
 *   mgmtPath: "A" | "B"   switch the diagram to that management path first
 *   focus / zoom          camera target when the scenario starts
 *   expandSecurity / expandRegionB   open those containers first
 * and each step can carry:
 *   badges: { nodeId: ["TEXT", "#color"] }   badge overrides for that phase
 * Scenarios without a dedicated branch below get a generic treatment:
 * "failure" steps pulse their affectedNodes red, other steps highlight them.
 */

class FailureSimulator {
  constructor(diagram, scenariosData) {
    this.diagram = diagram;
    this.scenarios = scenariosData;
    this.currentScenario = null;
    this.currentStepIndex = 0;
  }

  startScenario(scenarioId) {
    const scen = this.scenarios.find(s => s.id === scenarioId);
    if (scen && scen.mgmtPath && window.app) {
      window.app.setMgmtPath(scen.mgmtPath, { silent: true });
    }

    this.resetAll();
    this.currentScenario = scen;
    if (!this.currentScenario) return;

    if (scenarioId === "scenario-ha-failover") {
      this.diagram.securityVpcExpanded = true;
      this.diagram.render();
      this.diagram.focusOn("fw-pair-a", 1.25);
    } else if (scenarioId === "scenario-region-outage") {
      this.diagram.regionBCollapsed = false;
      this.diagram.render();
      this.diagram.focusOn("global", 0.85);
    } else {
      let dirty = false;
      if (scen.expandSecurity && !this.diagram.securityVpcExpanded) {
        this.diagram.securityVpcExpanded = true; dirty = true;
      }
      if (scen.expandRegionB && this.diagram.regionBCollapsed) {
        this.diagram.regionBCollapsed = false; dirty = true;
      }
      if (dirty) this.diagram.render();
      if (scen.focus) this.diagram.focusOn(scen.focus, scen.zoom || 1.1);
    }

    this.currentStepIndex = 0;
    this.applyCurrentStep();
  }

  nextStep() {
    if (!this.currentScenario) return;
    if (this.currentStepIndex < this.currentScenario.steps.length - 1) {
      this.currentStepIndex++;
      this.applyCurrentStep();
    }
  }

  prevStep() {
    if (!this.currentScenario) return;
    if (this.currentStepIndex > 0) {
      this.currentStepIndex--;
      this.applyCurrentStep();
    }
  }

  applyCurrentStep() {
    const step = this.currentScenario.steps[this.currentStepIndex];
    if (!step) return;

    // Re-render so badge/colour changes from a previous phase do not stick
    // when stepping backwards.
    this.diagram.render();

    // 1. Update UI
    if (window.app) {
      window.app.updateScenarioUI(this.currentScenario, step, this.currentStepIndex);
    }

    // 2. Visual state modifications on diagram nodes
    this.updateDiagramVisuals(step);
  }

  updateDiagramVisuals(step) {
    const svg = this.diagram.svg;

    // Reset temporary states
    svg.querySelectorAll(".arch-node").forEach(n => n.classList.remove("failing", "highlighted"));

    if (this.currentScenario.id === "scenario-ha-failover") {
      const fw1 = svg.querySelector("#node-fw1-a");
      const fw2 = svg.querySelector("#node-fw2-a");
      const untrust = svg.querySelector("#node-untrust-a");
      const trust = svg.querySelector("#node-trust-a");

      if (step.status === "failure") {
        if (fw1) {
          fw1.classList.add("failing");
          this.setNodeBadge(fw1, "DOWN", "#EF4444");
        }
      } else if (step.status === "action" || step.status === "restored") {
        if (fw1) {
          this.setNodeBadge(fw1, step.status === "restored" ? "PASSIVE" : "FAILED", step.status === "restored" ? "#64748B" : "#EF4444");
          fw1.querySelector("rect.node-card").style.stroke = step.status === "restored" ? "#64748B" : "#EF4444";
        }
        if (fw2) {
          this.setNodeBadge(fw2, "ACTIVE", "#10B981");
          fw2.querySelector("rect.node-card").style.stroke = "#10B981";
          fw2.querySelector("rect.node-card").style.strokeDasharray = "none";
          fw2.classList.add("highlighted");
        }
        if (step.phase && /remap|AWS/i.test(step.phase) || step.status === "restored") {
          if (untrust) {
            untrust.classList.add("highlighted");
            this.setNodeBadge(untrust, ".100+EIP ON FW2", "#10B981");
          }
          if (trust) {
            trust.classList.add("highlighted");
            this.setNodeBadge(trust, "ROUTES ➔ FW2", "#10B981");
          }
        }
      }
    } else if (this.currentScenario.id === "scenario-region-outage") {
      const regA = svg.querySelector("#region-a");
      const fw1a = svg.querySelector("#node-fw-pair-a") || svg.querySelector("#node-fw1-a");
      const fw2a = svg.querySelector("#node-fw2-a");
      const untrustA = svg.querySelector("#node-untrust-a");
      const dca = svg.querySelector("#node-dc-a");
      const fw1b = svg.querySelector("#node-fw1-b");
      const untrustB = svg.querySelector("#node-untrust-b");
      const dcb = svg.querySelector("#node-dc-b");
      const ga = svg.querySelector("#node-global-accelerator");

      const outage = ["failure", "action", "restored"].includes(step.status);
      if (outage) {
        if (regA) {
          regA.style.stroke = "#EF4444";
          // A translucent red veil over the whole region reads at any zoom;
          // it lives in the (pointer-events: none) animation layer.
          const anim = svg.querySelector("#animation-layer");
          const x = +regA.getAttribute("x"), y = +regA.getAttribute("y");
          const w = +regA.getAttribute("width"), h = +regA.getAttribute("height");
          if (anim) anim.insertAdjacentHTML("beforeend", `
            <g class="region-down-veil" pointer-events="none">
              <rect x="${x}" y="${y}" width="${w}" height="${h}" rx="16" fill="rgba(239,68,68,0.10)" stroke="#EF4444" stroke-width="2.5" stroke-dasharray="10 6" />
              <rect x="${x + w - 196}" y="${y + 14}" width="180" height="26" rx="6" fill="#7F1D1D" stroke="#EF4444" />
              <text x="${x + w - 106}" y="${y + 32}" fill="#FECACA" font-size="12" font-weight="700" text-anchor="middle">REGION A DOWN</text>
            </g>`);
        }
        [fw1a, fw2a, untrustA].forEach(n => {
          if (n) {
            n.classList.add("failing");
            this.setNodeBadge(n, "OUTAGE", "#EF4444");
          }
        });
      }

      if (step.status === "action" || step.status === "restored") {
        if (ga) ga.classList.add("highlighted");
        if (untrustB) {
          untrustB.classList.add("highlighted");
          this.setNodeBadge(untrustB, "SERVES A+B CLIENTS", "#10B981");
        }
        if (fw1b) fw1b.classList.add("highlighted");
      }
      if (step.status === "restored" && dcb) {
        dcb.classList.add("highlighted");
        this.setNodeBadge(dcb, "ACTIVE LDAP / DNS", "#10B981");
      }
      if (dca && outage) dca.style.opacity = "0.85";
    } else if (this.currentScenario.id === "scenario-panorama-outage") {
      const pano = svg.querySelector("#node-panorama");
      const fw1a = svg.querySelector("#node-fw-pair-a") || svg.querySelector("#node-fw1-a");
      const fw1b = svg.querySelector("#node-fw1-b");

      if (pano) {
        pano.classList.add("failing");
        this.setNodeBadge(pano, "OFFLINE", "#EF4444");
      }
      if (step.status === "restored") {
        [fw1a, fw1b].forEach(fw => {
          if (fw) {
            fw.classList.add("highlighted");
            this.setNodeBadge(fw, "DATAPLANE 100% OK", "#10B981");
          }
        });
      }
    } else if (this.currentScenario.id === "scenario-appliance-mode") {
      const tgw = svg.querySelector("#node-tgw-a");
      if (tgw) {
        tgw.classList.add("highlighted");
        if (step.status === "failure") {
          this.setNodeBadge(tgw, "ASYMMETRIC DROP", "#EF4444");
        } else {
          this.setNodeBadge(tgw, "APPLIANCE ON: OK", "#10B981");
        }
      }
    } else {
      // Generic data-driven scenario
      (step.affectedNodes || []).forEach(id => {
        const n = svg.querySelector(`#node-${id}`);
        if (!n) return;
        n.classList.add(step.status === "failure" ? "failing" : "highlighted");
      });
    }

    // Per-step badge overrides (any scenario)
    if (step.badges) {
      for (const [id, spec] of Object.entries(step.badges)) {
        const n = svg.querySelector(`#node-${id}`);
        if (n && Array.isArray(spec)) this.setNodeBadge(n, spec[0], spec[1]);
      }
    }
  }

  setNodeBadge(nodeElement, text, color) {
    if (!nodeElement) return;
    const badgeRect = nodeElement.querySelector("rect.node-badge");
    // Upstream looked for text[font-size='9'], but badges are drawn at 8.5,
    // so only the colour ever changed and the label kept its old text.
    const badgeText = nodeElement.querySelector("text.node-badge-text");
    if (badgeRect && badgeText) {
      badgeRect.style.fill = color;
      badgeText.textContent = text;
      // Widen the pill if the new label is longer than the old one.
      const need = Math.round(text.length * 8.5 * 0.62) + 16;
      const cur = parseFloat(badgeRect.getAttribute("width")) || 0;
      if (need > cur) {
        const x = parseFloat(badgeRect.getAttribute("x")) || 0;
        const card = nodeElement.querySelector("rect.node-card");
        const cardW = card ? parseFloat(card.getAttribute("width")) : 0;
        const pinnedRight = cardW && x > cardW / 2;
        const newX = pinnedRight ? Math.max(4, x - (need - cur)) : x;
        badgeRect.setAttribute("x", newX);
        badgeRect.setAttribute("width", need);
        badgeText.setAttribute("x", newX + need / 2);
      }
    }
  }

  resetAll() {
    this.currentScenario = null;
    this.currentStepIndex = 0;

    // Reset whole diagram styles
    this.diagram.clearLayers();
    this.diagram.render();
  }
}
