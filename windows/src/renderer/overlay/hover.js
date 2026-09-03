// hover.js
//
// The whole hover rule, in one place — a port of NotchWindowController's
// pointer handling and IslandPresentation's collapse lock.
//
// The overlay window is transparent to the mouse except over the drawn
// island, and Electron keeps forwarding pointer moves while it is
// click-through, so every move over the window's footprint lands here.
//
// Open and close use different zones on purpose. Opening asks for the island
// itself plus a lip below it — small, so the panel doesn't leap out at a
// pointer merely passing near. Closing asks for a much larger region around
// the open panel, so a pointer that overshoots a control by a few points
// doesn't shut it. The gap between the two is the hysteresis.

const SWEEP_SPEED = 900;      // px per second
const SWEEP_ASPECT = 2.5;     // |dx| vs |dy|
const SWEEP_RECHECK_MS = 80;
const COLLAPSE_LOCK_MS = 320; // covers the close spring
const HOT_PAD = 6;

const contains = (r, x, y) => x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height;

export class HoverController {
  /**
   * @param {object} options
   * @param {object} options.geometry   GEOMETRY from main
   * @param {() => {x:number,y:number,width:number,height:number}|null} options.drawnRect
   * @param {(hovering: boolean) => void} options.onHoverChange
   * @param {() => void} options.onVisited   pointer entered the island during an alert
   * @param {() => void} options.onHoveredAway
   */
  constructor({ geometry, drawnRect, onHoverChange, onVisited, onHoveredAway }) {
    this.geometry = geometry;
    this.drawnRect = drawnRect;
    this.onHoverChange = onHoverChange;
    this.onVisited = onVisited;
    this.onHoveredAway = onHoveredAway;

    this.isHovering = false;
    this.collapseLocked = false;
    this.interactive = null;
    this.lastMove = null;
    this.sweepRecheck = null;
    this.pointer = null;

    document.addEventListener('mousemove', (e) => this.onMove(e));
    document.addEventListener('mouseleave', () => this.onLeave());
    window.addEventListener('blur', () => this.refreshClickThrough());
    window.isle.onPointer((point) => this.onPoll(point));
  }

  /**
   * A polled cursor position from main, only while the island is open.
   * Forwarded moves stop the moment the pointer leaves the window's footprint
   * — frequently without a final event — so this is what notices the pointer
   * has gone and closes the panel. Never opens: opening stays event-driven so
   * the sweep rule keeps applying.
   */
  onPoll(point) {
    if (!this.isHovering) return;
    this.pointer = point;
    const zones = this.zones();
    if (!zones) return;
    if (!contains(zones.stayOpen, point.x, point.y)) {
      this.cancelRecheck();
      this.setHovering(false);
    }
    this.refreshClickThrough();
  }

  zones() {
    const drawn = this.drawnRect();
    if (!drawn) return null;
    const pad = this.geometry.stayOpenPad;
    return {
      open: { x: drawn.x, y: drawn.y, width: drawn.width, height: drawn.height + this.geometry.openLip },
      stayOpen: {
        x: drawn.x - pad.side, y: drawn.y - pad.top,
        width: drawn.width + pad.side * 2, height: drawn.height + pad.top + pad.bottom,
      },
    };
  }

  /** Clicks route to Isle only a hair around the visible island. */
  refreshClickThrough() {
    const drawn = this.drawnRect();
    let interactive = false;
    if (drawn && this.pointer) {
      const hot = { x: drawn.x - HOT_PAD, y: drawn.y - HOT_PAD, width: drawn.width + HOT_PAD * 2, height: drawn.height + HOT_PAD * 2 };
      interactive = contains(hot, this.pointer.x, this.pointer.y);
    }
    if (interactive !== this.interactive) {
      this.interactive = interactive;
      window.isle.setInteractive(interactive);
    }
  }

  /** Called every frame the island animates, so the hit box follows it. */
  tick() { this.refreshClickThrough(); }

  onMove(event) {
    this.pointer = { x: event.clientX, y: event.clientY };
    this.refreshClickThrough();

    // Measured on every move, in zone or out, so a sweep can't clear the gate
    // on its first frame over the island.
    const sweeping = this.isSweep(event);
    const zones = this.zones();
    if (!zones) return;
    const { x, y } = this.pointer;

    if (this.isHovering) {
      if (!contains(zones.stayOpen, x, y)) {
        this.cancelRecheck();
        this.setHovering(false);
      }
      return;
    }

    if (!contains(zones.open, x, y)) { this.cancelRecheck(); return; }

    // Arriving is instant; crossing is not. A fast sideways move through the
    // island is the pointer on its way somewhere else.
    if (sweeping) this.scheduleRecheck();
    else { this.cancelRecheck(); this.setHovering(true); }
  }

  onLeave() {
    this.pointer = null;
    this.cancelRecheck();
    this.setHovering(false);
    this.refreshClickThrough();
  }

  isSweep(event) {
    const now = performance.now() / 1000;
    const previous = this.lastMove;
    this.lastMove = { t: now, x: event.clientX, y: event.clientY };
    if (!previous) return false;
    const interval = now - previous.t;
    if (interval <= 0 || interval >= 0.2) return false;
    const dx = Math.abs(event.clientX - previous.x), dy = Math.abs(event.clientY - previous.y);
    return Math.hypot(dx, dy) / interval > SWEEP_SPEED && dx > dy * SWEEP_ASPECT;
  }

  scheduleRecheck() {
    if (this.sweepRecheck) return;
    this.sweepRecheck = setTimeout(() => {
      this.sweepRecheck = null;
      const zones = this.zones();
      if (!zones || !this.pointer) return;
      if (contains(zones.open, this.pointer.x, this.pointer.y)) this.setHovering(true);
    }, SWEEP_RECHECK_MS);
  }

  cancelRecheck() {
    if (this.sweepRecheck) clearTimeout(this.sweepRecheck);
    this.sweepRecheck = null;
  }

  /**
   * The only way hover changes. Opening is immediate; closing commits and
   * locks re-expansion out for the length of the close animation, so the
   * panel can't flap back open under a pointer on its way off the island.
   */
  setHovering(hovering) {
    if (hovering) {
      this.onVisited();
      if (this.collapseLocked || this.isHovering) return;
      this.isHovering = true;
      window.isle.pollPointer(true);
      this.onHoverChange(true);
    } else {
      if (!this.isHovering) return;
      this.isHovering = false;
      window.isle.pollPointer(false);
      this.onHoveredAway();
      this.collapseLocked = true;
      setTimeout(() => { this.collapseLocked = false; }, COLLAPSE_LOCK_MS);
      this.onHoverChange(false);
    }
  }

  /** Drop hover without the lock — used when a click dismisses the alert panel. */
  release() {
    if (!this.isHovering) return;
    this.isHovering = false;
    window.isle.pollPointer(false);
    this.onHoverChange(false);
  }
}
