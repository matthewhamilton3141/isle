// marquee.js
//
// Now-playing ticker for text that's too long for its slot. A horizontal
// offset animation — never an opacity flash. Text that fits is left static.
// The travel is a continuous cycle: the string is laid down twice with a gap
// and slid steadily left; by the time the first copy has fully left the frame
// the second sits exactly where the first began, so the loop restarts with
// nothing to see. CSS drives the slide, so this process does nothing while it
// plays.

export class Marquee {
  /**
   * @param {HTMLElement} host  an element with a fixed width and `overflow: hidden`
   * @param {{speed?: number, startDelay?: number, gap?: number}} options
   */
  constructor(host, { speed = 30, startDelay = 0.3, gap = 44 } = {}) {
    this.host = host;
    this.speed = speed;
    this.startDelay = startDelay;
    this.gap = gap;
    this.track = document.createElement('div');
    this.track.className = 'marquee-track';
    this.host.appendChild(this.track);
    this.text = null;
    this.builtWidth = 0;
  }

  setText(text) {
    const width = this.host.clientWidth;
    if (text === this.text && width === this.builtWidth) return;
    this.text = text;
    this.builtWidth = width;
    this.rebuild();
  }

  /** Re-measures against the host's current width (call after layout changes). */
  relayout() {
    if (this.host.clientWidth !== this.builtWidth) this.rebuild();
  }

  rebuild() {
    const { track, host, text } = this;
    track.innerHTML = '';
    track.style.animation = 'none';
    host.classList.remove('marquee-scrolls');
    if (!text) return;

    const first = document.createElement('span');
    first.className = 'marquee-copy';
    first.textContent = text;
    track.appendChild(first);
    const width = host.clientWidth;
    this.builtWidth = width;
    const textWidth = Math.ceil(first.getBoundingClientRect().width);
    if (textWidth <= width || width === 0) return;

    const second = first.cloneNode(true);
    second.style.marginLeft = `${this.gap}px`;
    track.appendChild(second);
    const distance = textWidth + this.gap;
    track.style.setProperty('--marquee-distance', `-${distance}px`);
    // Forcing a reflow so the restart of the animation is honoured.
    void track.offsetWidth;
    track.style.animation = `marquee-slide ${distance / this.speed}s linear ${this.startDelay}s infinite`;
    host.classList.add('marquee-scrolls');
  }
}
