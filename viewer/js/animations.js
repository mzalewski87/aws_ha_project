/**
 * Traffic Flow Animation Engine
 * Creates animated SVG packet particles moving along network paths with step narration.
 */

class TrafficFlowAnimator {
  constructor(diagram, flowsData) {
    this.diagram = diagram;
    this.flows = flowsData;
    this.currentFlow = null;
    this.currentStepIndex = 0;
    this.isPlaying = false;
    this.animationTimer = null;
    this.activeParticles = [];

    this.animLayer = this.diagram.svg.querySelector("#animation-layer");
  }

  startFlow(flowId) {
    this.stop();
    this.currentFlow = this.flows.find(f => f.id === flowId);
    if (!this.currentFlow) return;

    // Expand relevant zones if subnets or cross-region are involved
    if (["flow-gp-vpn", "flow-inbound-app", "flow-outbound-egress", "flow-east-west"].includes(flowId)) {
      if (!this.diagram.securityVpcExpanded) {
        this.diagram.securityVpcExpanded = true;
        this.diagram.render();
      }
    }
    if (["flow-mgmt-plane", "flow-ad-replication"].includes(flowId)) {
      if (this.diagram.regionBCollapsed) {
        this.diagram.regionBCollapsed = false;
        this.diagram.render();
      }
    }

    this.animLayer = this.diagram.svg.querySelector("#animation-layer");
    this.currentStepIndex = 0;
    this.isPlaying = true;
    this.renderStep();
  }

  renderStep() {
    this.animLayer = this.diagram.svg.querySelector("#animation-layer");
    this.clearParticles();
    if (!this.currentFlow) return;

    const step = this.currentFlow.steps[this.currentStepIndex];
    if (!step) return;

    // Update Narration UI
    if (window.app) {
      window.app.updateFlowNarration(this.currentFlow, step, this.currentStepIndex);
    }

    // Highlight active nodes
    this.diagram.clearHighlights();
    step.nodes.forEach(nodeId => {
      const el = this.diagram.svg.querySelector(`#node-${nodeId}`);
      if (el) el.classList.add("highlighted");
    });

    // Spawn animated particles between consecutive nodes
    this.spawnParticlesForNodes(step.nodes, this.currentFlow.color);

    // Auto advance if playing
    if (this.isPlaying) {
      clearTimeout(this.animationTimer);
      this.animationTimer = setTimeout(() => {
        this.nextStep();
      }, 4500);
    }
  }

  nextStep() {
    if (!this.currentFlow) return;
    this.currentStepIndex++;
    if (this.currentStepIndex >= this.currentFlow.steps.length) {
      this.currentStepIndex = 0; // Loop back
    }
    this.renderStep();
  }

  prevStep() {
    if (!this.currentFlow) return;
    this.currentStepIndex--;
    if (this.currentStepIndex < 0) {
      this.currentStepIndex = this.currentFlow.steps.length - 1;
    }
    this.renderStep();
  }

  togglePlay() {
    this.isPlaying = !this.isPlaying;
    if (this.isPlaying) {
      this.renderStep();
    } else {
      clearTimeout(this.animationTimer);
    }
    return this.isPlaying;
  }

  spawnParticlesForNodes(nodes, color) {
    if (nodes.length < 2) return;

    for (let i = 0; i < nodes.length - 1; i++) {
      const srcId = nodes[i];
      const dstId = nodes[i + 1];
      const p1 = this.diagram.nodePositions[srcId];
      const p2 = this.diagram.nodePositions[dstId];
      if (!p1 || !p2) continue;

      this.createMovingParticle(p1.cx, p1.cy, p2.cx, p2.cy, color, i * 600);
    }
  }

  createMovingParticle(x1, y1, x2, y2, color, delayMs) {
    const particleGroup = document.createElementNS("http://www.w3.org/2000/svg", "g");
    particleGroup.setAttribute("class", "flow-particle");

    // Glow circle + solid center
    particleGroup.innerHTML = `
      <circle r="8" fill="${color}" opacity="0.4" />
      <circle r="4" fill="#FFFFFF" />
    `;

    this.animLayer.appendChild(particleGroup);
    this.activeParticles.push(particleGroup);

    const startTime = performance.now() + delayMs;
    const duration = 1800; // ms

    const animate = (currentTime) => {
      if (!this.activeParticles.includes(particleGroup)) return;

      if (currentTime < startTime) {
        requestAnimationFrame(animate);
        return;
      }

      const elapsed = currentTime - startTime;
      const progress = Math.min((elapsed % duration) / duration, 1);

      // Linear interpolation with slight smooth curve
      const currX = x1 + (x2 - x1) * progress;
      const currY = y1 + (y2 - y1) * progress;

      particleGroup.setAttribute("transform", `translate(${currX}, ${currY})`);

      if (this.isPlaying) {
        requestAnimationFrame(animate);
      }
    };

    requestAnimationFrame(animate);
  }

  clearParticles() {
    clearTimeout(this.animationTimer);
    this.activeParticles = [];
    if (this.animLayer) {
      this.animLayer.innerHTML = "";
    }
  }

  stop() {
    this.isPlaying = false;
    clearTimeout(this.animationTimer);
    this.clearParticles();
    this.currentFlow = null;
    this.diagram.clearHighlights();
  }
}
