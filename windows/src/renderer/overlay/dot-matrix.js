// dot-matrix.js
//
// Renders a marker: a 5x5 grid of dots described by a design (see
// shared/markers.js). A canvas port of DotMatrixView/DotMatrixCurves: every
// animation is a pure function of wall-clock time, drawn at ~30fps. The dots
// morph when the design changes — the old lit layout eases into the new one
// over `MORPH` seconds, so dots slide on and off rather than cutting.

import { DIMENSION, DOT_COUNT, DESIGNS } from '../shared/markers.js';
import { hexToRgba, lerp, lightened, FALLBACK_PALETTE } from '../shared/colors.js';

const MORPH = 0.45;
const fract = (x) => x - Math.floor(x);

function levelsFor(design) {
  const ghost = design.ghost ? 0.08 : 0;
  return Array.from({ length: DOT_COUNT }, (_, i) => (design.dots[i] ? 1 : ghost));
}

function animationValue(design, row, col, clock) {
  const speed = design.speed;
  switch (design.animation) {
    case 'solid': return 0.82 + 0.18 * (0.5 + 0.5 * Math.sin(clock * speed * 0.5));
    case 'shimmer': return 0.30 + 0.70 * (0.5 + 0.5 * Math.sin(clock * speed + row * 0.8 + col * 0.55));
    case 'pulse': return 0.35 + 0.65 * (0.5 + 0.5 * Math.sin(clock * speed));
    case 'blink': return Math.sin(clock * speed) > 0 ? 1 : 0.12;
    case 'motion': {
      // An evolving plasma: a rotating plane wave, a ripple from the centre
      // and a second wave crossing the other way, so it never settles into an
      // obvious repeat.
      const t = clock * speed * 0.32;
      const a = t * 0.8;
      const w1 = Math.sin((col * Math.cos(a) + row * Math.sin(a)) * 1.5 + t * 2.0);
      const dist = Math.hypot(col - 2, row - 2);
      const w2 = Math.sin(dist * 1.7 - t * 2.6);
      const b = -a * 0.6;
      const w3 = Math.sin((col * Math.sin(b) + row * Math.cos(b)) * 1.1 + t * 1.3);
      return 0.18 + 0.82 * (0.5 + 0.5 * (w1 + w2 + w3) / 3);
    }
    case 'compact': {
      // A full box collapses one line at a time from the top, down to a
      // single row, then refills — a triangle over the cycle.
      const n = DIMENSION;
      const tri = Math.abs(2 * fract(clock * speed * 0.18) - 1);
      const fillCount = 1 + tri * (n - 1);
      const cutoff = n - fillCount;
      const e = Math.min(1, Math.max(0, row - (cutoff - 0.5)));
      return 0.10 + 0.90 * (e * e * (3 - 2 * e));
    }
    default: return 1;
  }
}

export class DotMatrix {
  /**
   * @param {HTMLCanvasElement} canvas
   */
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.design = DESIGNS.disconnected;
    this.palette = FALLBACK_PALETTE;
    this.tint = null;
    this.levels = levelsFor(this.design);
    this.fromLevels = this.levels;
    this.morphStart = -Infinity;
    this.epoch = performance.now() / 1000;
    this.resolveColors();
  }

  /** Applies a design; a lit-dot change morphs, a colour/speed change just retunes. */
  apply(design, palette, tint) {
    const changedDots = design.dots !== this.design.dots;
    if (changedDots) {
      const now = performance.now() / 1000;
      this.fromLevels = this.currentLevels(now);
      this.morphStart = now;
      this.levels = levelsFor(design);
    }
    this.design = design;
    this.palette = palette || FALLBACK_PALETTE;
    this.tint = tint || null;
    this.resolveColors();
  }

  resolveColors() {
    const fixed = this.tint || hexToRgba(this.design.fixedColorHex);
    this.colors = {
      fixed,
      fixedLift: lightened(fixed, 0.35),
      forceFixed: !!this.tint || this.design.colorMode === 'fixed',
      stops: [this.palette.primary, this.palette.accent, this.palette.secondary],
    };
  }

  currentLevels(now) {
    const t = Math.min(1, Math.max(0, (now - this.morphStart) / MORPH));
    if (t >= 1) return this.levels;
    const eased = t * t * (3 - 2 * t);
    return this.levels.map((to, i) => this.fromLevels[i] + (to - this.fromLevels[i]) * eased);
  }

  colorAt(row, col, clock) {
    const { fixed, fixedLift, forceFixed, stops } = this.colors;
    if (forceFixed) {
      // Subtle per-dot brightness variation so a fixed colour still lives.
      const u = 0.5 + 0.5 * Math.sin(clock * 0.9 + (row + col) * 0.5);
      return lerp(fixed, fixedLift, u * 0.6);
    }
    // A colour that drifts along the palette and differs per dot.
    const u = fract(row * 0.19 + col * 0.13 + clock * 0.05);
    const seg = u * stops.length;
    const i = Math.floor(seg) % stops.length;
    return lerp(stops[i], stops[(i + 1) % stops.length], seg - Math.floor(seg));
  }

  /** Draws one frame at the canvas's current CSS size. */
  draw(nowMs = performance.now()) {
    const { canvas, ctx, design } = this;
    const dpr = window.devicePixelRatio || 1;
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (width === 0 || height === 0) return;
    const pw = Math.round(width * dpr), ph = Math.round(height * dpr);
    if (canvas.width !== pw || canvas.height !== ph) { canvas.width = pw; canvas.height = ph; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);

    const now = nowMs / 1000;
    const clock = now - this.epoch;
    const side = Math.min(width, height);
    const cell = side / DIMENSION;
    const ox = (width - side) / 2, oy = (height - side) / 2;
    const levels = this.currentLevels(now);

    for (let row = 0; row < DIMENSION; row++) {
      for (let col = 0; col < DIMENSION; col++) {
        const level = levels[row * DIMENSION + col];
        if (level <= 0.001) continue;
        const value = design.intensity * level * animationValue(design, row, col, clock);
        if (value <= 0.02) continue;
        const radius = cell * 0.5 * (0.28 + 0.55 * Math.min(1, value)) + 0.5;
        const alpha = (0.10 + 0.90 * Math.min(1, value));
        const color = this.colorAt(row, col, clock);
        ctx.fillStyle = `rgba(${Math.round(color.r * 255)}, ${Math.round(color.g * 255)}, ${Math.round(color.b * 255)}, ${alpha * color.a})`;
        ctx.beginPath();
        ctx.arc(ox + (col + 0.5) * cell, oy + (row + 0.5) * cell, radius, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }
}
