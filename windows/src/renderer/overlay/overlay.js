// overlay.js
//
// Root of the island. Takes the state snapshots main pushes, derives what the
// island shows (view-model.js), lays the collapsed and expanded faces out,
// and animates the notch shape between them with the Mac app's springs.
//
// The window never resizes — it was created at its maximum extent — so this
// file is also responsible for reporting the island's live rect to the hover
// controller, which keeps clicks outside the drawn shape passing through.

import { MediaModel } from './media-model.js';
import { derive, COLLAPSED, clockString, timeString } from './view-model.js';
import { HoverController } from './hover.js';
import { Spring, SPRINGS } from './spring.js';
import { DotMatrix } from './dot-matrix.js';
import { Equalizer } from './equalizer.js';
import { Marquee } from './marquee.js';
import { AudioLevels } from './audio-levels.js';
import { DESIGNS } from '../shared/markers.js';
import { toCss } from '../shared/colors.js';
import { ICONS, dotGrid, waveformIcon } from '../shared/icons.js';

const GEOMETRY = window.isle.geometry;
const $ = (id) => document.getElementById(id);

// MARK: - State

let settings = { effectiveMode: 'both' };
let claude = { state: 'disconnected' };
let pomodoro = { phase: 'focus', isActive: false, isRunning: false, phaseDuration: 1500, remainingWhenPaused: 1500, completedInCycle: 0 };
let activeTab = 'music';
const alert = { dismissed: false, wasHovered: false, tabOverridden: false };
let lastClaudeState = 'disconnected';
let vm = null;
let expanded = false;
let renderQueued = false;

const media = new MediaModel(scheduleRender);
const audio = new AudioLevels();

// MARK: - Text measurement

const measureCache = new Map();
function measure(text, font) {
  const key = `${font}|${text}`;
  if (measureCache.has(key)) return measureCache.get(key);
  const span = $(font === 'clock' ? 'measure-clock' : 'measure-status');
  if (!span) return 0;
  span.textContent = text;
  const width = Math.max(0, Math.ceil(span.getBoundingClientRect().width));
  measureCache.set(key, width);
  return width;
}

// MARK: - Components (persistent, reparented as the layout changes)

const dotsCollapsed = makeDots('dots-collapsed');
const dotsExpanded = new DotMatrix($('dots-expanded'));
const eqCollapsed = makeEqualizer();
const eqExpanded = new Equalizer($('eq-expanded'));
const ringCollapsed = makeRing();
const thumb = makeThumb();
const statusText = el('span', 'status-text');
const clockSmall = el('span', 'clock-small');
const marqueeTitle = new Marquee($('marquee-title'));
const marqueeArtist = new Marquee($('marquee-artist'));

function el(tag, className) { const e = document.createElement(tag); if (className) e.className = className; return e; }

function makeDots(id) {
  const host = el('div', 'dots');
  const canvas = el('canvas'); canvas.id = id;
  host.appendChild(canvas);
  return { host, matrix: new DotMatrix(canvas) };
}

function makeEqualizer() {
  const host = el('div', 'wave-slot');
  const canvas = el('canvas');
  host.appendChild(canvas);
  return { host, eq: new Equalizer(canvas) };
}

function makeRing() {
  const host = el('div', 'ring-small');
  host.innerHTML = `<svg class="ring" viewBox="0 0 16 16"><circle class="ring-track" cx="8" cy="8" r="7"></circle><circle class="ring-fill" cx="8" cy="8" r="7"></circle></svg>`;
  return { host, track: host.querySelector('.ring-track'), fill: host.querySelector('.ring-fill') };
}

function makeThumb() {
  const host = el('div', 'thumb');
  const img = el('img');
  host.appendChild(img);
  return { host, img };
}

/** Sets a ring's progress (0…1), tint and stroke width. */
function setRing(track, fill, progress, tint, lineWidth) {
  const r = Number(fill.getAttribute('r'));
  const circumference = 2 * Math.PI * r;
  track.style.stroke = tint;
  fill.style.stroke = tint;
  track.style.strokeWidth = lineWidth;
  fill.style.strokeWidth = lineWidth;
  fill.style.strokeDasharray = `${circumference}`;
  fill.style.strokeDashoffset = `${circumference * (1 - Math.min(1, Math.max(0, progress)))}`;
}

// MARK: - Notch geometry + springs

const notch = $('notch');
const stage = $('stage');
const width = new Spring(GEOMETRY.idle.width);
const height = new Spring(GEOMETRY.idle.height);
const topRadius = new Spring(8);
const bottomRadius = new Spring(12);
const shift = new Spring(0);
let target = { width: GEOMETRY.idle.width, height: GEOMETRY.idle.height, shift: 0 };

function notchPath(w, h, top, bottom) {
  const maxRadius = Math.min(w, h) / 2;
  const t = Math.min(top, maxRadius), b = Math.min(bottom, maxRadius);
  return `M0 0 Q${t} 0 ${t} ${t} L${t} ${h - b} Q${t} ${h} ${t + b} ${h} L${w - t - b} ${h} Q${w - t} ${h} ${w - t} ${h - b} L${w - t} ${t} Q${w - t} 0 ${w} 0 Z`;
}

function frameRect(w, h, s) {
  return { x: (stage.clientWidth - w) / 2 + s, y: 0, width: w, height: h };
}

/** The island's clickable region: union of the target frame and the live one. */
function drawnRect() {
  const a = frameRect(target.width, target.height, target.shift);
  const b = frameRect(width.value, height.value, shift.value);
  const x = Math.min(a.x, b.x), y = 0;
  const right = Math.max(a.x + a.width, b.x + b.width);
  return { x, y, width: right - x, height: Math.max(a.height, b.height) };
}

// MARK: - Hover

const hover = new HoverController({
  geometry: GEOMETRY,
  drawnRect,
  onHoverChange: () => scheduleRender(),
  onVisited: () => { if (vm && vm.hasLiveActivity) alert.wasHovered = true; },
  onHoveredAway: () => {
    if (vm && vm.hasLiveActivity && alert.wasHovered && settings.dismissAlertPanel) alert.dismissed = true;
  },
});

function dismissAlert() {
  if (!vm || !vm.hasLiveActivity || !settings.dismissAlertPanel) return;
  alert.dismissed = true;
  hover.release();
  scheduleRender();
}

// MARK: - Render

function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  queueMicrotask(() => { renderQueued = false; render(); });
}

function render() {
  try {
    vm = derive({
      settings, claude, pomodoro, media: media.media, artworkPalette: media.artworkPalette,
      measure, alert, activeTab,
    });

    const wasExpanded = expanded;
    expanded = vm.autoExpandsForActivity || hover.isHovering;

    // Target geometry.
    if (expanded) {
      target = { width: GEOMETRY.expanded.width, height: GEOMETRY.expanded.height, shift: 0 };
    } else if (vm.isCollapsedIdle) {
      target = { width: GEOMETRY.idle.width, height: GEOMETRY.idle.height, shift: 0 };
    } else {
      let w = GEOMETRY.cutout.width + vm.sides.leading + vm.sides.trailing + COLLAPSED.hPadding;
      const s = Number.isFinite(vm.sides.trailing) && Number.isFinite(vm.sides.leading) ? (vm.sides.trailing - vm.sides.leading) / 2 : 0;
      if (!Number.isFinite(w)) {
        console.error('[overlay] invalid collapsed width, using idle. sides:', JSON.stringify(vm.sides));
        w = GEOMETRY.idle.width;
      }
      target = { width: w, height: GEOMETRY.cutout.height, shift: s };
    }
    const curve = expanded ? SPRINGS.open : SPRINGS.close;
    width.to(target.width, curve);
    height.to(target.height, curve);
    shift.to(target.shift, curve);
    topRadius.to(expanded ? 12 : 8, curve);
    bottomRadius.to(expanded ? 22 : 12, curve);
    if (expanded !== wasExpanded) hover.refreshClickThrough();

    const paletteCss = { p1: toCss(vm.palette.primary), p2: toCss(vm.palette.secondary) };
    notch.style.setProperty('--p1', paletteCss.p1);
    notch.style.setProperty('--p2', paletteCss.p2);

    renderCollapsed();
    renderExpanded();
    syncAudio();
  } catch (error) {
    console.error('[overlay] render failed:', error);
  }
}

// MARK: - Collapsed face

function renderCollapsed() {
  const leading = $('leading'), trailing = $('trailing');
  if (!vm || !Number.isFinite(vm.sides.leading) || !Number.isFinite(vm.sides.trailing)) {
    console.error('[overlay] invalid vm.sides, clearing collapsed:', vm && JSON.stringify(vm.sides));
    leading.style.width = `${COLLAPSED.minSide}px`;
    trailing.style.width = `${COLLAPSED.minSide}px`;
    leading.replaceChildren();
    trailing.replaceChildren();
    return;
  }
  leading.style.width = `${vm.sides.leading}px`;
  trailing.style.width = `${vm.sides.trailing}px`;
  $('cutout').style.width = `${GEOMETRY.cutout.width}px`;

  const m = media.media;
  const design = DESIGNS[vm.markerKind] || DESIGNS.disconnected;
  dotsCollapsed.matrix.apply(design, vm.palette, vm.workingTint);
  dotsExpanded.apply(design, vm.palette, null);

  // Artwork thumbnail.
  if (m.artwork) { thumb.img.src = m.artwork; thumb.img.style.display = 'block'; }
  else { thumb.img.removeAttribute('src'); thumb.img.style.display = 'none'; }

  // Status word + colour, matched to the dots.
  statusText.textContent = vm.collapsedStatusText;
  statusText.style.color = vm.workingTint ? toCss(vm.workingTint)
    : design.colorMode === 'fixed' ? design.fixedColorHex : toCss(vm.palette.accent);

  clockSmall.style.width = `${vm.pomodoroClockWidth}px`;

  const pomodoroTint = toCss(vm.palette[pomodoro.isBreak ? 'secondary' : 'accent']);
  ringCollapsed.host.classList.toggle('paused', !pomodoro.isRunning);
  ringCollapsed.tint = pomodoroTint;

  const waveSlot = () => {
    eqCollapsed.host.style.visibility = vm.showsWaveform ? 'visible' : 'hidden';
    return eqCollapsed.host;
  };
  const dots = (size) => {
    dotsCollapsed.host.style.width = `${size}px`;
    dotsCollapsed.host.style.height = `${size}px`;
    return dotsCollapsed.host;
  };
  const ring = (size) => {
    ringCollapsed.host.classList.toggle('large', size >= COLLAPSED.album);
    ringCollapsed.lineWidth = size >= COLLAPSED.album ? 2.5 : 2;
    return ringCollapsed.host;
  };
  const pomodoroCluster = () => {
    const cluster = el('div', 'cluster');
    cluster.append(ring(COLLAPSED.dots), clockSmall);
    return cluster;
  };

  const leadingNodes = [], trailingNodes = [];
  if (vm.shouldSplitCollapsed) {
    leadingNodes.push(thumb.host);
    trailingNodes.push(waveSlot());
    if (vm.hasClaudeActivity) trailingNodes.push(dots(COLLAPSED.dots), statusText);
    if (vm.pomodoroOnTrailingSide) trailingNodes.push(pomodoroCluster());
  } else if (vm.isClaudeSolo) {
    leadingNodes.push(dots(COLLAPSED.album));
    trailingNodes.push(statusText);
    if (vm.pomodoroOnTrailingSide) trailingNodes.push(pomodoroCluster());
  } else if (vm.isPomodoroSolo) {
    leadingNodes.push(ring(COLLAPSED.album));
    trailingNodes.push(clockSmall);
  } else if (vm.hasMusicActivity) {
    leadingNodes.push(thumb.host);
    trailingNodes.push(waveSlot());
  }
  leading.replaceChildren(...leadingNodes);
  trailing.replaceChildren(...trailingNodes);
}

// MARK: - Expanded face

function renderExpanded() {
  const m = media.media;

  // Tab bar.
  const tabbar = $('tabbar');
  tabbar.style.display = vm.showsTabBar ? 'flex' : 'none';
  const wanted = vm.availableTabs.join(',');
  if (tabbar.dataset.tabs !== wanted) {
    tabbar.dataset.tabs = wanted;
    tabbar.replaceChildren(...vm.availableTabs.map((tab) => {
      const button = el('button', 'tab-button');
      button.dataset.tab = tab;
      button.setAttribute('aria-label', tab);
      button.innerHTML = tab === 'music' ? waveformIcon() : tab === 'claude' ? dotGrid(3) : ICONS.timer;
      button.addEventListener('click', () => selectTab(tab));
      return button;
    }));
  }
  for (const button of tabbar.children) button.classList.toggle('active', button.dataset.tab === vm.expandedTab);

  for (const tab of ['music', 'claude', 'pomodoro']) {
    $(`tab-${tab}`).classList.toggle('active', vm.expandedTab === tab);
  }

  // Waveform pinned top-right, on every tab, only with a live track.
  $('wave-expanded').style.display = m.hasTrack && vm.showsWaveform ? 'block' : 'none';

  // Music.
  const hasTrack = m.hasTrack;
  $('music-track').classList.toggle('hidden', !hasTrack);
  $('music-idle').classList.toggle('shown', !hasTrack);
  const artwork = $('artwork');
  if (m.artwork) { artwork.src = m.artwork; artwork.style.display = 'block'; }
  else { artwork.removeAttribute('src'); artwork.style.display = 'none'; }
  const placeholder = $('artwork-placeholder');
  placeholder.style.display = m.artwork ? 'none' : 'flex';
  placeholder.innerHTML = m.artwork ? '' : ICONS.musicNote;
  if (hasTrack) {
    marqueeTitle.setText(m.title || 'Not playing');
    marqueeArtist.setText(m.artist || '');
  }
  $('scrubber').style.display = vm.showScrubber ? 'flex' : 'none';
  $('scrubber').classList.toggle('disabled', !media.canSeek);
  $('controls').classList.toggle('no-scrubber', !vm.showScrubber);
  $('controls').classList.toggle('disabled', !media.canControlPlayback);
  $('btn-shuffle').classList.toggle('hidden', !vm.showShuffleRepeat);
  $('btn-repeat').classList.toggle('hidden', !vm.showShuffleRepeat);
  $('btn-shuffle').classList.toggle('off', !m.isShuffled);
  $('btn-repeat').classList.toggle('off', m.repeatMode === 'off');
  $('btn-repeat').innerHTML = m.repeatMode === 'one' ? ICONS.repeatOne : ICONS.repeat;
  $('btn-play').innerHTML = m.isPlaying ? ICONS.pause : ICONS.play;
  $('btn-prev').innerHTML = ICONS.backward;
  $('btn-next').innerHTML = ICONS.forward;
  $('btn-shuffle').innerHTML = ICONS.shuffle;
  updateScrubber(Date.now());

  // Claude.
  const state = vm.claudeState;
  const headlines = {
    disconnected: 'No active session', idle: 'Ready', working: `${vm.workingWord}\u2026`,
    needsApproval: 'Has a question', needsQuestion: 'Has a question', waitingInput: 'Waiting for you',
    done: 'Done', failed: 'Error', compacting: 'Compacting',
  };
  const details = {
    working: vm.activity || 'Thinking\u2026',
    needsApproval: vm.activity || 'Answer to keep it moving',
    needsQuestion: vm.activity || 'Answer to keep it moving',
    waitingInput: "It's ready for your next prompt",
    done: 'Finished responding',
    idle: 'Session ready',
    failed: 'The turn stopped on an error \u2014 resend to retry.',
    compacting: 'Compacting the conversation to free up context',
    disconnected: 'Install the Claude Code hook to connect a session',
  };
  $('claude-headline').textContent = headlines[state] || 'Ready';
  $('claude-detail').textContent = details[state] || '';
  const project = $('claude-project');
  if (claude.project) { project.innerHTML = `${ICONS.folder}<span></span>`; project.lastChild.textContent = claude.project; }
  else project.replaceChildren();
  updateClaudeMeta();

  // Pomodoro.
  $('pomodoro-headline').textContent = pomodoro.phaseTitle || 'Focus';
  $('pomodoro-detail').textContent = pomodoro.isRunning
    ? (pomodoro.isBreak ? 'Step away \u2014 the next focus waits for you' : 'Heads down')
    : pomodoro.isActive ? 'Paused'
      : (pomodoro.isBreak ? 'Ready when you are' : 'Press play to start a focus session');
  const tint = toCss(vm.palette[pomodoro.isBreak ? 'secondary' : 'accent']);
  const dotsHost = $('cycle-dots');
  const total = vm.sessionsPerCycle;
  if (dotsHost.children.length !== total) dotsHost.replaceChildren(...Array.from({ length: total }, () => el('i')));
  [...dotsHost.children].forEach((dot, i) => { dot.style.background = i < pomodoro.completedInCycle ? tint : ''; });
  $('pom-reset').innerHTML = ICONS.reset;
  $('pom-reset').classList.toggle('off', !pomodoro.isActive);
  $('pom-reset').disabled = !pomodoro.isActive;
  $('pom-toggle').innerHTML = pomodoro.isRunning ? ICONS.pause : ICONS.play;
  $('pom-skip').innerHTML = ICONS.skipEnd;
  updatePomodoroClocks(Date.now(), true);

  for (const button of document.querySelectorAll('.control[data-size]')) {
    const size = Number(button.dataset.size);
    button.style.fontSize = `${size}px`;
    button.style.width = `${size + 7}px`;
    button.style.height = `${size + 7}px`;
  }
}

function selectTab(tab) {
  if (vm && vm.hasLiveActivity) alert.tabOverridden = true;
  activeTab = tab;
  window.isle.updateSettings({ lastTab: tab });
  scheduleRender();
}

// MARK: - Per-frame updates

function updateScrubber(now) {
  const m = media.media;
  if (!m.hasTrack) return;
  const progress = media.displayProgress(now);
  const elapsed = progress * m.duration;
  $('scrub-fill').style.width = `${Math.max(0, progress * 100)}%`;
  $('time-elapsed').textContent = timeString(elapsed);
  $('time-remaining').textContent = '-' + timeString(Math.max(0, m.duration - elapsed));
}

let lastClockText = '';
function updatePomodoroClocks(now, force = false) {
  const remaining = pomodoro.endDate != null ? Math.max(0, (pomodoro.endDate - now) / 1000) : pomodoro.remainingWhenPaused;
  const text = clockString(remaining);
  const progress = pomodoro.phaseDuration > 0 ? Math.min(1, Math.max(0, 1 - remaining / pomodoro.phaseDuration)) : 0;
  const tint = toCss(vm.palette[pomodoro.isBreak ? 'secondary' : 'accent']);
  if (force || text !== lastClockText) {
    lastClockText = text;
    clockSmall.textContent = text;
    clockSmall.style.color = tint;
    const large = $('pomodoro-clock-large');
    large.textContent = text;
    large.classList.toggle('hours', remaining >= 3600);
  }
  setRing(ringCollapsed.track, ringCollapsed.fill, progress, ringCollapsed.tint || tint, ringCollapsed.lineWidth || 2);
  const ringLarge = $('ring-expanded');
  setRing(ringLarge.querySelector('.ring-track'), ringLarge.querySelector('.ring-fill'), progress, tint, 6);
}

let lastMetaText = '';
function updateClaudeMeta() {
  const meta = $('claude-meta');
  let text = '';
  if (claude.updatedAt && vm.claudeState !== 'disconnected') {
    const seconds = Math.max(0, Math.floor((Date.now() - claude.updatedAt) / 1000));
    text = seconds < 60 ? `${seconds}s ago` : seconds < 3600 ? `${Math.floor(seconds / 60)}m ago` : `${Math.floor(seconds / 3600)}h ago`;
  }
  if (text !== lastMetaText) { lastMetaText = text; meta.textContent = text; }
}

let lastFrame = performance.now();
let canvasFrame = 0;
function frame(now) {
  const dt = Math.min(0.05, (now - lastFrame) / 1000);
  lastFrame = now;
  for (const s of [width, height, topRadius, bottomRadius, shift]) s.step(dt);

  const w = width.value, h = height.value;
  notch.style.width = `${w}px`;
  notch.style.height = `${h}px`;
  notch.style.left = `${(stage.clientWidth - w) / 2 + shift.value}px`;
  notch.style.clipPath = `path('${notchPath(w, h, topRadius.value, bottomRadius.value)}')`;

  // 0 when fully collapsed, 1 when fully expanded, tracking the animation.
  // Height is a better crossfade signal than width because the collapsed
  // island can be very wide (music + claude + pomodoro) without being open.
  const collapsedH = GEOMETRY.cutout.height, expandedH = GEOMETRY.expanded.height;
  const progress = Math.min(1, Math.max(0, (h - collapsedH) / (expandedH - collapsedH)));
  // The expanded content stays hidden until the notch is ~65% open, then
  // fades in over the rest of the travel; the collapsed face fades early.
  const expandedOpacity = Math.min(1, Math.max(0, (progress - 0.65) / 0.3));
  const collapsedOpacity = Math.max(0, 1 - progress / 0.35);
  $('expanded').style.opacity = expandedOpacity;
  $('expanded').style.pointerEvents = expandedOpacity > 0.5 ? 'auto' : 'none';
  $('collapsed').style.opacity = collapsedOpacity;
  $('collapsed').style.visibility = collapsedOpacity > 0.01 ? 'visible' : 'hidden';

  if (vm) {
    const nowMs = Date.now();
    if (expanded && vm.expandedTab === 'music') updateScrubber(nowMs);
    if (vm.hasPomodoroActivity || (expanded && vm.expandedTab === 'pomodoro')) updatePomodoroClocks(nowMs);
    if (expanded && vm.expandedTab === 'claude') updateClaudeMeta();

    // Canvases at ~30fps.
    if ((canvasFrame++ & 1) === 0) {
      const levels = audio.isLive ? audio.levels : null;
      const isPlaying = media.media.isPlaying;
      if (collapsedOpacity > 0.01) {
        if (vm.hasClaudeActivity) dotsCollapsed.matrix.draw(now);
        if (vm.hasMusicActivity && vm.showsWaveform) {
          eqCollapsed.eq.configure({ palette: vm.palette, isPlaying, levels });
          eqCollapsed.eq.draw(now);
        }
      }
      if (expandedOpacity > 0.01) {
        if (vm.expandedTab === 'claude') dotsExpanded.draw(now);
        if (media.media.hasTrack && vm.showsWaveform) {
          eqExpanded.configure({ palette: vm.palette, isPlaying, levels });
          eqExpanded.draw(now);
        }
      }
    }
  }

  hover.tick();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// MARK: - Audio capture gating

function syncAudio() {
  const m = media.media;
  const wants = vm.showsMusic && vm.listens && vm.showsWaveform && m.hasTrack && m.isPlaying;
  if (wants && !audio.active) audio.start();
  else if (!wants && audio.active) audio.stop();
}

// MARK: - Interaction

$('btn-play').addEventListener('click', () => media.togglePlayPause());
$('btn-next').addEventListener('click', () => media.nextTrack());
$('btn-prev').addEventListener('click', () => media.previousTrack());
$('btn-shuffle').addEventListener('click', () => media.toggleShuffle());
$('btn-repeat').addEventListener('click', () => media.toggleRepeat());
$('pom-toggle').addEventListener('click', () => window.isle.pomodoro.toggle());
$('pom-skip').addEventListener('click', () => window.isle.pomodoro.skip());
$('pom-reset').addEventListener('click', () => window.isle.pomodoro.reset());
$('tab-claude').addEventListener('click', dismissAlert);

const scrubHit = $('scrub-hit');
scrubHit.addEventListener('pointerdown', (event) => {
  if (!media.canSeek) return;
  scrubHit.setPointerCapture(event.pointerId);
  const rect = scrubHit.getBoundingClientRect();
  const update = (e) => { media.scrubTarget = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)); };
  update(event);
  const move = (e) => update(e);
  const up = () => {
    scrubHit.removeEventListener('pointermove', move);
    scrubHit.removeEventListener('pointerup', up);
    scrubHit.removeEventListener('pointercancel', up);
    // Seek once on release rather than on every sample.
    media.commitScrub();
  };
  scrubHit.addEventListener('pointermove', move);
  scrubHit.addEventListener('pointerup', up);
  scrubHit.addEventListener('pointercancel', up);
});

// MARK: - Pomodoro chime

function chime() {
  try {
    const ctx = new AudioContext();
    const now = ctx.currentTime;
    [[880, 0], [1174.66, 0.18]].forEach(([freq, at]) => {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, now + at);
      gain.gain.exponentialRampToValueAtTime(0.18, now + at + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + at + 0.9);
      osc.connect(gain).connect(ctx.destination);
      osc.start(now + at);
      osc.stop(now + at + 1);
    });
    setTimeout(() => ctx.close(), 1500);
  } catch { /* no audio device */ }
}

// MARK: - State from main

window.isle.onState((state) => {
  if (state.settings) {
    settings = state.settings;
    if (settings.lastTab && activeTab !== settings.lastTab) activeTab = settings.lastTab;
  }
  if (state.claude) {
    claude = state.claude;
    // Re-arm the dismiss state whenever the actual state changes, so a fresh
    // alert opens even if the previous one was dismissed.
    if (claude.state !== lastClaudeState) {
      lastClaudeState = claude.state;
      alert.dismissed = false;
      alert.wasHovered = false;
      alert.tabOverridden = false;
    }
  }
  if (state.pomodoro) pomodoro = state.pomodoro;
  if (state.media) media.receive(state.media);
  scheduleRender();
});

window.isle.onPomodoroEnded(() => chime());


window.isle.getState().then((state) => {
  if (state.settings) { settings = state.settings; activeTab = settings.lastTab || 'music'; }
  if (state.claude) { claude = state.claude; lastClaudeState = claude.state; }
  if (state.pomodoro) pomodoro = state.pomodoro;
  if (state.media) media.receive(state.media);
  // Snap to the resting size on first paint rather than springing from zero.
  render();
  width.snap(target.width); height.snap(target.height); shift.snap(target.shift);
});
