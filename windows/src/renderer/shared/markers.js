// markers.js
//
// The designs for each dot-matrix marker: which of the 25 dots are lit, how
// they're coloured, how they animate. A port of MarkerDesign.swift's defaults
// (the Windows build has no marker editor, so these are the designs).
// This is an original mark, not a copy of Anthropic's.

export const DIMENSION = 5;
export const DOT_COUNT = 25;

function grid(lit) {
  const dots = new Array(DOT_COUNT).fill(false);
  for (const i of lit) if (i >= 0 && i < DOT_COUNT) dots[i] = true;
  return dots;
}

// Common shapes in the 5x5 grid (index = row*5 + col).
const exclamation = grid([2, 7, 12, 22]);
const checkmark = grid([4, 8, 10, 12, 16]);
const question = grid([1, 2, 3, 8, 12, 22]);
const cross = grid([0, 4, 6, 8, 12, 16, 18, 20, 24]);
const midRow = grid([10, 12, 14]);
const full = new Array(DOT_COUNT).fill(true);

export const HEX = {
  red: '#FF3B30', amber: '#FF9F0A', green: '#34C759', blue: '#0A84FF', cyan: '#32ADE6', gray: '#8E8E93',
};

const design = (dots, colorMode, fixedColorHex, animation, speed, intensity, ghost = true) =>
  Object.freeze({ dots, colorMode, fixedColorHex, animation, speed, intensity, ghost });

export const DESIGNS = Object.freeze({
  disconnected: design(full, 'fixed', HEX.gray, 'pulse', 1.0, 0.18),
  idle: design(full, 'palette', HEX.gray, 'pulse', 1.6, 0.45),
  working: design(full, 'palette', HEX.blue, 'motion', 3.2, 1.0),
  done: design(checkmark, 'fixed', HEX.green, 'solid', 2.0, 1.0),
  needsApproval: design(question, 'fixed', HEX.blue, 'pulse', 3.5, 1.0),
  needsQuestion: design(question, 'fixed', HEX.blue, 'pulse', 3.5, 1.0),
  apiError: design(cross, 'fixed', HEX.red, 'pulse', 4.0, 1.0),
  serverError: design(cross, 'fixed', HEX.red, 'blink', 3.0, 1.0),
  rateLimited: design(exclamation, 'fixed', HEX.amber, 'blink', 2.0, 1.0),
  waitingInput: design(midRow, 'palette', HEX.blue, 'shimmer', 1.6, 1.0),
  compacting: design(full, 'palette', HEX.cyan, 'compact', 2.2, 0.9),
});

/** The marker to render for a Claude state, with the failure kind refined
 *  from `errorType` so the glyph itself distinguishes them. */
export function markerKind(state, errorType) {
  if (state !== 'failed') return DESIGNS[state] ? state : 'disconnected';
  switch (errorType) {
    case 'usage_limit': case 'rate_limit': case 'rate_limit_error': case 'rate_limited': return 'rateLimited';
    case 'server_error': case 'api_error': case 'overloaded': case 'overloaded_error': return 'serverError';
    default: return 'apiError';
  }
}
