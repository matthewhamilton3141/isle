// geometry.js
//
// The island's sizes, shared by the main process (which sizes the window)
// and the renderer (which draws inside it). The Windows port has no camera
// housing, so these are the Mac app's non-notched fallback numbers: a pill
// hugging the top edge of the screen, with a small central "cutout" that
// keeps the two clusters reading as two mini-displays either side of a
// divider, the way the camera divides them on a MacBook.
//
// The window is created at its maximum extent and never resized — only the
// content animates — so this also fixes how much dead margin the window has
// around the drawn panel for the hover "stay open" pad.

const GEOMETRY = Object.freeze({
  // The stand-in for the camera cutout. Height is the collapsed island's
  // height; width is the gap between the music and Claude clusters.
  cutout: { width: 74, height: 32 },
  // Resting size when there is nothing to show: a bare pill, still hoverable.
  idle: { width: 120, height: 32 },
  expanded: { width: 520, height: 146 },
  // How far outside the drawn panel the pointer may stray before it collapses.
  stayOpenPad: { top: 10, side: 16, bottom: 26 },
  // How far below the collapsed island the open zone reaches.
  openLip: 0,
});

const WINDOW = Object.freeze({
  width: GEOMETRY.expanded.width + GEOMETRY.stayOpenPad.side * 2,
  height: GEOMETRY.expanded.height + GEOMETRY.stayOpenPad.bottom,
});

module.exports = { GEOMETRY, WINDOW };
