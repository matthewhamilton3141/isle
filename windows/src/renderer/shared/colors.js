// colors.js
//
// Colour plumbing shared by the overlay and Settings: hex parsing, the palette
// pulled from album art (ArtworkColors.swift), and the Claude accent swatches
// that supply a palette when there is no artwork (ClaudeAccent.swift).
//
// A palette is three RGBA stops: `primary` the base, `secondary` the deep
// stop, `accent` the highlight. The dot-matrix ramp walks primary → accent →
// secondary and wraps, the equalizer gradient runs primary → accent.

export function hexToRgba(hex) {
  const cleaned = String(hex || '').replace(/[#\s]/g, '');
  const value = parseInt(cleaned.padEnd(6, '0').slice(0, 6), 16) || 0;
  return { r: ((value >> 16) & 255) / 255, g: ((value >> 8) & 255) / 255, b: (value & 255) / 255, a: 1 };
}

export function rgba(r, g, b, a = 1) { return { r, g, b, a }; }

export function toCss({ r, g, b, a = 1 }, alpha = a) {
  return `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${alpha})`;
}

export function lerp(from, to, t) {
  return {
    r: from.r + (to.r - from.r) * t,
    g: from.g + (to.g - from.g) * t,
    b: from.b + (to.b - from.b) * t,
    a: from.a + (to.a - from.a) * t,
  };
}

export function lightened(c, amount) {
  return { r: c.r + (1 - c.r) * amount, g: c.g + (1 - c.g) * amount, b: c.b + (1 - c.b) * amount, a: c.a };
}

/** Neutral palette for when there's no artwork and no accent. */
export const FALLBACK_PALETTE = Object.freeze({
  primary: rgba(0.45, 0.45, 0.45),
  secondary: rgba(0.30, 0.30, 0.30),
  accent: rgba(0.60, 0.60, 0.60),
});

// MARK: - Artwork

const GRID = 8;
let scratch = null;

function sample(image) {
  if (!scratch) {
    scratch = document.createElement('canvas');
    scratch.width = GRID; scratch.height = GRID;
  }
  const ctx = scratch.getContext('2d', { willReadFrequently: true });
  ctx.clearRect(0, 0, GRID, GRID);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'medium';
  // Drawing the whole image into an 8×8 context is the downscale — the
  // interpolation does the averaging.
  ctx.drawImage(image, 0, 0, GRID, GRID);
  const data = ctx.getImageData(0, 0, GRID, GRID).data;
  const samples = [];
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] / 255 <= 0.5) continue;
    samples.push({ r: data[i] / 255, g: data[i + 1] / 255, b: data[i + 2] / 255 });
  }
  return samples;
}

const brightness = (s) => (s.r + s.g + s.b) / 3;
const saturation = (s) => { const mx = Math.max(s.r, s.g, s.b), mn = Math.min(s.r, s.g, s.b); return mx > 0 ? (mx - mn) / mx : 0; };
/** Favour colours that are both colourful and not nearly black/white. */
const vibrancy = (s) => saturation(s) * (1 - Math.abs(brightness(s) - 0.55) * 1.4);
const distance = (a, b) => Math.hypot(a.r - b.r, a.g - b.g, a.b - b.b);

/** Lift very dark samples so the gradient stays visible against black. */
function withMinBrightness(s, min) {
  const current = brightness(s);
  if (current <= 0 || current >= min) return rgba(s.r, s.g, s.b);
  const scale = min / current;
  return rgba(Math.min(1, s.r * scale), Math.min(1, s.g * scale), Math.min(1, s.b * scale));
}

/** Palette from a decoded HTMLImageElement, or the fallback. */
export function paletteFromImage(image) {
  let samples;
  try { samples = image ? sample(image) : []; } catch { samples = []; }
  if (!samples.length) return FALLBACK_PALETTE;
  const ranked = samples.sort((a, b) => vibrancy(b) - vibrancy(a));
  const primary = ranked[0];
  const secondary = ranked.find((s) => distance(s, primary) > 0.25) || ranked[Math.min(1, ranked.length - 1)];
  const accent = ranked.find((s) => distance(s, primary) > 0.35 && distance(s, secondary) > 0.25) || primary;
  return {
    primary: withMinBrightness(primary, 0.35),
    secondary: withMinBrightness(secondary, 0.28),
    accent: withMinBrightness(accent, 0.45),
  };
}

// MARK: - Claude accent

const SWATCH_PALETTES = {
  lime: ['#9DC63F', '#5F8A24', '#CDEA6A'],
  teal: ['#25BFA4', '#127A6B', '#7FE9C8'],
  violet: ['#9438E0', '#6321A6', '#C79BFF'],
  orchid: ['#CE5FD2', '#8F2F96', '#F0A6EE'],
  magenta: ['#E44C8E', '#A62760', '#FF95B8'],
  slate: ['#AFB9CB', '#556A8C', '#DCE3ED'],
  stone: ['#C2B096', '#907C58', '#EDE4D8'],
};

export const ACCENT_SWATCHES = ['lime', 'teal', 'violet', 'orchid', 'magenta', 'slate', 'stone'];

export const ACCENT_TITLES = {
  lime: 'Lime', teal: 'Teal', violet: 'Violet', orchid: 'Orchid', magenta: 'Magenta',
  slate: 'Slate', stone: 'Stone', custom: 'Custom',
};

function rgbToHsv({ r, g, b }) {
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  let h = 0;
  if (d > 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h /= 6;
    if (h < 0) h += 1;
  }
  return { h, s: max > 0 ? d / max : 0, v: max };
}

function hsvToRgb(h, s, v) {
  const i = Math.floor(h * 6), f = h * 6 - i;
  const p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
  const [r, g, b] = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i % 6];
  return rgba(r, g, b);
}

const rotate = (hue, degrees) => { const s = hue + degrees / 360; return s - Math.floor(s); };

/** Builds a full palette from a single picked colour (ClaudeAccent.derive). */
export function derivePalette(hex) {
  const { h, s, v } = rgbToHsv(hexToRgba(hex));
  const sat = Math.max(s, 0.35);
  const val = Math.max(v, 0.58);
  return {
    primary: hsvToRgb(h, sat, val),
    secondary: hsvToRgb(rotate(h, -6), Math.min(1, sat * 1.12), Math.max(0.30, val * 0.62)),
    accent: hsvToRgb(rotate(h, 8), Math.max(0.10, sat * 0.60), Math.min(1, val * 1.30)),
  };
}

/** The palette for an accent setting. */
export function accentPalette(accent, customHex) {
  if (accent === 'custom') return derivePalette(customHex);
  const stops = SWATCH_PALETTES[accent] || SWATCH_PALETTES.violet;
  return { primary: hexToRgba(stops[0]), secondary: hexToRgba(stops[1]), accent: hexToRgba(stops[2]) };
}

/** The chip colour for the picker — the primary stop, as CSS. */
export function accentChip(accent, customHex) {
  return toCss(accentPalette(accent, customHex).primary);
}

// MARK: - Collision check (Settings caption)

const RESERVED = [
  ['errors', '#FF3B30'], ['rate limits', '#FF9F0A'], ['success', '#34C759'],
  ['questions', '#0A84FF'], ['plan review', '#32ADE6'],
];

function lab({ r, g, b }) {
  const lin = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  const R = lin(r), G = lin(g), B = lin(b);
  const x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047;
  const y = 0.2126 * R + 0.7152 * G + 0.0722 * B;
  const z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883;
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  const fx = f(x), fy = f(y), fz = f(z);
  return { l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz) };
}

/** The reserved colour a custom accent could be confused with, or null. */
export function accentCollision(hex) {
  const stops = derivePalette(hex);
  const labs = [stops.primary, stops.secondary, stops.accent].map(lab);
  let nearest = null;
  for (const [name, reservedHex] of RESERVED) {
    const target = lab(hexToRgba(reservedHex));
    for (const stop of labs) {
      const d = Math.hypot(stop.l - target.l, stop.a - target.a, stop.b - target.b);
      if (d < 30 && (!nearest || d < nearest.d)) nearest = { name, d };
    }
  }
  return nearest ? nearest.name : null;
}
