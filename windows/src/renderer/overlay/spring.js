// spring.js
//
// A SwiftUI-style spring on a scalar, parameterised by `response` and
// `dampingFraction` so the island's curves can be quoted verbatim from the
// Mac app: opening is underdamped (response 0.34, damping 0.76 — the
// overshoot on the way open is the part that feels good), closing is
// critically damped (0.30, 1.0) so the collapsed pill can never undershoot.

export const SPRINGS = Object.freeze({
  open: { response: 0.34, dampingFraction: 0.76 },
  close: { response: 0.30, dampingFraction: 1.0 },
});

export class Spring {
  constructor(value = 0) {
    this.value = value;
    this.target = value;
    this.velocity = 0;
    this.setCurve(SPRINGS.close);
  }

  setCurve({ response, dampingFraction }) {
    const omega = (2 * Math.PI) / response;
    this.stiffness = omega * omega;
    this.damping = 2 * dampingFraction * omega;
  }

  /** Retargets; the current velocity carries over so a mid-flight change blends. */
  to(target, curve) {
    if (curve) this.setCurve(curve);
    this.target = target;
  }

  snap(value) {
    this.value = value;
    this.target = value;
    this.velocity = 0;
  }

  get settled() {
    return Math.abs(this.value - this.target) < 0.05 && Math.abs(this.velocity) < 0.5;
  }

  /** Advances by `dt` seconds. Sub-stepped so a dropped frame can't explode. */
  step(dt) {
    if (this.settled) { this.value = this.target; this.velocity = 0; return; }
    const steps = Math.max(1, Math.ceil(dt / (1 / 240)));
    const h = dt / steps;
    for (let i = 0; i < steps; i++) {
      const acceleration = -this.stiffness * (this.value - this.target) - this.damping * this.velocity;
      this.velocity += acceleration * h;
      this.value += this.velocity * h;
    }
  }
}
