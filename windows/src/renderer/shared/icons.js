// icons.js
//
// A small SVG glyph set standing in for the SF Symbols the Mac app uses. All
// drawn on a 24-unit box, filled/stroked with currentColor, so they inherit
// the text colour and can be sized by the CSS `font-size` of their box.

const svg = (body, extra = '') =>
  `<svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor" ${extra} aria-hidden="true">${body}</svg>`;

const stroke = 'fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"';

export const ICONS = {
  play: svg('<path d="M7 4.5v15a1 1 0 0 0 1.53.85l12-7.5a1 1 0 0 0 0-1.7l-12-7.5A1 1 0 0 0 7 4.5z"/>'),
  pause: svg('<rect x="5" y="4" width="5" height="16" rx="1.5"/><rect x="14" y="4" width="5" height="16" rx="1.5"/>'),
  backward: svg('<path d="M11.5 5.6v12.8a1 1 0 0 1-1.55.83l-8-6.4a1 1 0 0 1 0-1.66l8-6.4a1 1 0 0 1 1.55.83z"/><path d="M22 5.6v12.8a1 1 0 0 1-1.55.83l-8-6.4a1 1 0 0 1 0-1.66l8-6.4A1 1 0 0 1 22 5.6z"/>'),
  forward: svg('<path d="M12.5 5.6v12.8a1 1 0 0 0 1.55.83l8-6.4a1 1 0 0 0 0-1.66l-8-6.4a1 1 0 0 0-1.55.83z"/><path d="M2 5.6v12.8a1 1 0 0 0 1.55.83l8-6.4a1 1 0 0 0 0-1.66l-8-6.4A1 1 0 0 0 2 5.6z"/>'),
  skipEnd: svg('<path d="M4 5.6v12.8a1 1 0 0 0 1.55.83l9-6.4a1 1 0 0 0 0-1.66l-9-6.4A1 1 0 0 0 4 5.6z"/><rect x="17" y="5" width="3" height="14" rx="1.2"/>'),
  shuffle: svg(`<g ${stroke}><path d="M3 6h3.5c1.6 0 3 .8 3.9 2.1L14.6 15.9c.9 1.3 2.3 2.1 3.9 2.1H21"/><path d="M3 18h3.5c1.6 0 3-.8 3.9-2.1l.7-1.1"/><path d="M13.7 9.2l.9-1.1c.9-1.3 2.3-2.1 3.9-2.1H21"/><path d="M18 3l3 3-3 3"/><path d="M18 15l3 3-3 3"/></g>`),
  repeat: svg(`<g ${stroke}><path d="M17 3l3 3-3 3"/><path d="M20 6H8a5 5 0 0 0-5 5v1"/><path d="M7 21l-3-3 3-3"/><path d="M4 18h12a5 5 0 0 0 5-5v-1"/></g>`),
  repeatOne: svg(`<g ${stroke}><path d="M17 3l3 3-3 3"/><path d="M20 6H8a5 5 0 0 0-5 5v1"/><path d="M7 21l-3-3 3-3"/><path d="M4 18h12a5 5 0 0 0 5-5v-1"/></g><path d="M12.9 9.2h-1.6l-1.6 1v1.5l1.4-.8v4.3h1.8z"/>`),
  reset: svg(`<g ${stroke}><path d="M4 11a8 8 0 1 1 2.3 5.7"/><path d="M4 5v6h6"/></g>`),
  musicNote: svg('<path d="M9 3.5v11.1a3.8 3.8 0 1 0 2 3.3V8.2l8-2.2v5.6a3.8 3.8 0 1 0 2 3.3V2.5a1 1 0 0 0-1.27-.96l-10 2.75A1 1 0 0 0 9 5.25z"/>'),
  folder: svg('<path d="M3 6.5A2.5 2.5 0 0 1 5.5 4h4.3a2 2 0 0 1 1.4.6L12.8 6H18.5A2.5 2.5 0 0 1 21 8.5v9A2.5 2.5 0 0 1 18.5 20h-13A2.5 2.5 0 0 1 3 17.5z"/>'),
  timer: svg(`<g ${stroke}><circle cx="12" cy="13.5" r="7.5"/><path d="M12 9.5v4l2.6 1.6"/><path d="M9.5 3h5"/></g>`),
  sparkle: svg('<path d="M12 2c.6 4.9 3.1 7.4 8 8-4.9.6-7.4 3.1-8 8-.6-4.9-3.1-7.4-8-8 4.9-.6 7.4-3.1 8-8z"/>'),
  split: svg(`<g ${stroke}><rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M12 5v14"/></g>`),
  waveform: svg('<rect x="2.5" y="9.5" width="2.6" height="5" rx="1.3"/><rect x="7.3" y="5.5" width="2.6" height="13" rx="1.3"/><rect x="12.1" y="8" width="2.6" height="8" rx="1.3"/><rect x="16.9" y="3.5" width="2.6" height="17" rx="1.3"/><rect x="21.2" y="9" width="2.6" height="6" rx="1.3" transform="translate(-1.5 0)"/>'),
  checkCircle: svg('<path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm4.6 7.4-5.3 5.6a1.1 1.1 0 0 1-1.6 0L7.4 12.6a1 1 0 1 1 1.4-1.4l1.7 1.7 4.5-4.9a1 1 0 0 1 1.5 1.4z"/>'),
  circle: svg(`<circle cx="12" cy="12" r="9.5" fill="none" stroke="currentColor" stroke-width="1.8"/>`),
  checkSquare: svg('<path d="M5.5 3h13A2.5 2.5 0 0 1 21 5.5v13a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 18.5v-13A2.5 2.5 0 0 1 5.5 3zm11.1 6.4a1 1 0 0 0-1.5-1.4l-4.5 4.9-1.7-1.7a1 1 0 1 0-1.4 1.4l2.3 2.4a1.1 1.1 0 0 0 1.6 0z"/>'),
  square: svg('<rect x="3.9" y="3.9" width="16.2" height="16.2" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/>'),
  warning: svg('<path d="M10.3 3.9a2 2 0 0 1 3.4 0l8 14A2 2 0 0 1 20 21H4a2 2 0 0 1-1.7-3.1zM12 9a1 1 0 0 0-1 1v4a1 1 0 0 0 2 0v-4a1 1 0 0 0-1-1zm0 9a1.3 1.3 0 1 0 0-2.6 1.3 1.3 0 0 0 0 2.6z"/>'),
  gear: svg('<path d="M10.4 2.5h3.2l.5 2.3c.6.2 1.1.5 1.6.9l2.2-.8 1.6 2.8-1.7 1.5c.1.6.1 1.2 0 1.8l1.7 1.5-1.6 2.8-2.2-.8c-.5.4-1 .7-1.6.9l-.5 2.3h-3.2l-.5-2.3c-.6-.2-1.1-.5-1.6-.9l-2.2.8-1.6-2.8 1.7-1.5a6 6 0 0 1 0-1.8L4.5 7.7l1.6-2.8 2.2.8c.5-.4 1-.7 1.6-.9zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z" transform="translate(0 2)"/>'),
  headphones: svg(`<g ${stroke}><path d="M4 14v-2a8 8 0 0 1 16 0v2"/><path d="M4 14h2.5a1.5 1.5 0 0 1 1.5 1.5v3A1.5 1.5 0 0 1 6.5 20H5.5A1.5 1.5 0 0 1 4 18.5z"/><path d="M20 14h-2.5a1.5 1.5 0 0 0-1.5 1.5v3a1.5 1.5 0 0 0 1.5 1.5h1a1.5 1.5 0 0 0 1.5-1.5z"/></g>`),
};

/** A 3×3 (or n×n) dot grid, the Claude tab mark. */
export function dotGrid(dimension = 3, fill = 0.30) {
  const cell = 24 / dimension;
  const r = cell * fill;
  let body = '';
  for (let row = 0; row < dimension; row++) {
    for (let col = 0; col < dimension; col++) {
      body += `<circle cx="${(col + 0.5) * cell}" cy="${(row + 0.5) * cell}" r="${r}"/>`;
    }
  }
  return svg(body);
}

/** A 4-bar waveform, the Music tab mark (WaveformIcon.swift). */
export function waveformIcon(heights = [0.3, 0.7, 0.5, 0.62], thickness = 0.62) {
  const cell = 24 / heights.length;
  const barWidth = cell * thickness;
  let body = '';
  heights.forEach((h, i) => {
    const cx = (i + 0.5) * cell;
    const barHeight = Math.max(barWidth, h * 24);
    body += `<rect x="${cx - barWidth / 2}" y="${12 - barHeight / 2}" width="${barWidth}" height="${barHeight}" rx="${barWidth / 2}"/>`;
  });
  return svg(body);
}
