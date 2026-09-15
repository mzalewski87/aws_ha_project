/**
 * Disaster Recovery & Failure Scenarios Engine
 * Interactively models component failures, AWS API failover actions, and traffic recovery.
 */

class FailureSimulator {
  constructor(diagram, scenariosData) {
    this.diagram = diagram;
    this.scenarios = scenariosData;
    this.currentScenario = null;
    this.currentStepIndex = 0;
  }

  startScenario(scenarioId) {
    this.resetAll();
    this.currentScenario = this.scenarios.find(s => s.id === scenarioId);
    if (!this.currentScenario) return;

    if (scenarioId === "scenario-ha-failover") {
      this.diagram.securityVpcExpanded = true;
      this.diagram.render();
      this.diagram.focusOn("fw-pair-a", 1.25);
    } else if (scenarioId === "scenario-region-outage") {
      this.diagram.regionBCollapsed = false;
      this.diagram.render();
      this.diagram.focusOn("global", 0.85);
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
    svg.querySelectorAll(".arch-node").forEach(n => n.classList.remove("failing"));

    if (this.currentScenario.id === "scenario-ha-failover") {
      const fw1 = svg.querySelector("#node-fw1-a");
      const fw2 = svg.querySelector("#node-fw2-a");
      const untrust = svg.querySelector("#node-untrust-a");

      if (step.status === "failure") {
        if (fw1) {
          fw1.classList.add("failing");
          this.setNodeBadge(fw1, "DOWN", "#EF4444");
        }
      } else if (step.status === "action" || step.status === "restored") {
        if (fw1) {
          this.setNodeBadge(fw1, "STOPPED", "#EF4444");
          fw1.querySelector("rect.node-card").style.stroke = "#EF4444";
        }
        if (fw2) {
          this.setNodeBadge(fw2, "ACTIVE", "#10B981");
          fw2.querySelector("rect.node-card").style.stroke = "#10B981";
          fw2.querySelector("rect.node-card").style.strokeDasharray = "none";
          fw2.classList.add("highlighted");
        }
        if (untrust) {
          untrust.classList.add("highlighted");
          this.setNodeBadge(untrust, "ON FW2", "#10B981");
        }
      }
    } else if (this.currentScenario.id === "scenario-region-outage") {
      const regA = svg.querySelector("#region-a");
      const fw1a = svg.querySelector("#node-fw1-a");
      const fw2a = svg.querySelector("#node-fw2-a");
      const dca = svg.querySelector("#node-dc-a");
      const fw1b = svg.querySelector("#node-fw1-b");
      const dcb = svg.querySelector("#node-dc-b");
      const ga = svg.querySelector("#node-global-accelerator");

      if (step.status === "failure" || step.status === "action" || step.status === "restored") {
        if (regA) {
          regA.style.opacity = "0.35";
          regA.style.stroke = "#EF4444";
        }
        [fw1a, fw2a, dca].forEach(n => {
          if (n) {
            n.classList.add("failing");
            this.setNodeBadge(n, "OUTAGE", "#EF4444");
          }
        });
      }

      if (step.status === "action" || step.status === "restored") {
        if (ga) {
          ga.classList.add("highlighted");
          this.setNodeBadge(ga, "ROUTING TO B", "#00F0FF");
        }
        if (fw1b) {
          fw1b.classList.add("highlighted");
          this.setNodeBadge(fw1b, "SERVING ANYCAST", "#10B981");
        }
        if (dcb) {
          dcb.classList.add("highlighted");
          this.setNodeBadge(dcb, "ACTIVE LDAP", "#10B981");
        }
      }
    } else if (this.currentScenario.id === "scenario-panorama-outage") {
      const pano = svg.querySelector("#node-panorama");
      const fw1a = svg.querySelector("#node-fw1-a");
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
    }
  }

  setNodeBadge(nodeElement, text, color) {
    if (!nodeElement) return;
    const badgeRect = nodeElement.querySelector("rect.node-badge");
    const badgeText = nodeElement.querySelector("text[font-size='9']");
    if (badgeRect && badgeText) {
      badgeRect.style.fill = color;
      badgeText.textContent = text;
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
