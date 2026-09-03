// equalizer.js
//
// The six-bar waveform, a canvas port of EqualizerLayer.swift. Bars grow
// symmetrically out of a centre line, so silence resolves to a row of dots and
// sound pushes them open from the middle. One vertical gradient spans the
// whole strip and every bar samples it over its own height, so a tall bar
// picks up the full ramp while a short one stays near the middle tone — the
// colour encodes amplitude.
//
// Three modes: live (real per-band levels), procedural (each bar its own sine
// while something plays and nothing is listening), resting (dots).

import { FALLBACK_PALETTE, toCss } from '../shared/colors.js';

const BAR_COUNT = 6;
const BAR_THICKNESS = 2.5;
const DOT_HEIGHT = 2.5;
const MIN_SPACING = 1.2;
const FREQUENCIES = [1.00, 1.37, 0.83, 1.61, 1.13, 0.71];
const PHASES = [0.0, 0.9, 1.8, 0.45, 2.3, 1.35];

export class Equalizer {
  /** @param {HTMLCanvasElement} canvas */
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.palette = FALLBACK_PALETTE;
    this.isPlaying = false;
    this.levels = null;      // Array of 6 (0…1) when live, else null
    this.epoch = performance.now() / 1000;
  }

  configure({ palette, isPlaying, levels }) {
    this.palette = palette || FALLBACK_PALETTE;
    this.isPlaying = !!isPlaying;
    this.levels = levels && levels.length >= BAR_COUNT ? levels : null;
  }

  get mode() {
    if (this.levels) return 'live';
    return this.isPlaying ? 'procedural' : 'resting';
  }

  /** Whether a frame would draw anything different from the last. Resting is static. */
  get animates() { return this.mode !== 'resting'; }

  geometry(width) {
    const gaps = BAR_COUNT - 1;
    const spacing = (width - BAR_THICKNESS * BAR_COUNT) / gaps;
    if (spacing >= MIN_SPACING) return { barWidth: BAR_THICKNESS, spacing };
    return { barWidth: Math.max(1, (width - MIN_SPACING * gaps) / BAR_COUNT), spacing: MIN_SPACING };
  }

  levelAt(index, clock) {
    switch (this.mode) {
      case 'live': return Math.min(1, Math.max(0, this.levels[index]));
      case 'procedural': {
        const f = FREQUENCIES[index % FREQUENCIES.length], p = PHASES[index % PHASES.length];
        return 0.18 + (Math.sin(clock * f * 3.1 + p) + 1) / 2 * 0.72;
      }
      default: return 0;
    }
  }

  draw(nowMs = performance.now()) {
    const { canvas, ctx } = this;
    const dpr = window.devicePixelRatio || 1;
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (!width || !height) return;
    const pw = Math.round(width * dpr), ph = Math.round(height * dpr);
    if (canvas.width !== pw || canvas.height !== ph) { canvas.width = pw; canvas.height = ph; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);

    const clock = nowMs / 1000 - this.epoch;
    const { barWidth, spacing } = this.geometry(width);

    // The bars are the mask; the gradient is what shows through.
    ctx.save();
    ctx.beginPath();
    for (let i = 0; i < BAR_COUNT; i++) {
      const level = this.levelAt(i, clock);
      const full = Math.max(DOT_HEIGHT, height * level);
      const x = i * (barWidth + spacing);
      const y = (height - full) / 2;
      const radius = Math.min(barWidth, full) / 2;
      ctx.roundRect(x, y, barWidth, full, radius);
    }
    ctx.clip();
    // Bottom to top, primary to accent.
    const gradient = ctx.createLinearGradient(0, height, 0, 0);
    gradient.addColorStop(0, toCss(this.palette.primary));
    gradient.addColorStop(1, toCss(this.palette.accent));
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, width, height);
    ctx.restore();
  }
}
