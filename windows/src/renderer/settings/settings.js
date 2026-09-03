// settings.js
//
// The Settings window: a sidebar of General, the feature pages the active
// mode brings, Pomodoro, and About. Every control writes straight through to
// main, which restarts only the affected subsystems live.

import { ICONS, dotGrid } from '../shared/icons.js';
import { ACCENT_SWATCHES, ACCENT_TITLES, accentChip, accentCollision } from '../shared/colors.js';

const sidebar = document.getElementById('sidebar');
const detail = document.getElementById('detail');

let state = null;
let page = 'general';
let hookMessage = null;

const update = (partial) => window.isle.updateSettings(partial);
const s = () => state.settings;

// MARK: - Controls

function el(tag, className, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text != null) e.textContent = text;
  return e;
}

function row(label, control, caption) {
  const wrap = el('div', caption ? 'stack' : 'row');
  const r = caption ? el('div', 'row') : wrap;
  r.append(el('span', 'label', label));
  const value = el('div', 'value');
  value.append(control);
  r.append(value);
  if (caption) {
    wrap.append(r);
    const c = el('div', 'caption');
    if (typeof caption === 'string') c.textContent = caption; else c.append(caption);
    wrap.append(c);
  }
  return wrap;
}

function toggle(key, onChange) {
  const b = el('button', `switch${s()[key] ? ' on' : ''}`);
  b.setAttribute('role', 'switch');
  b.addEventListener('click', () => { const next = !s()[key]; update({ [key]: next }); if (onChange) onChange(next); });
  return b;
}

function segmented(key, options) {
  const wrap = el('div', 'segmented');
  for (const [value, label] of options) {
    const b = el('button', s()[key] === value ? 'active' : '', label);
    b.addEventListener('click', () => update({ [key]: value }));
    wrap.append(b);
  }
  return wrap;
}

function stepper(key, min, max, format) {
  const wrap = el('div', 'value');
  const value = el('span', 'mono', format(s()[key]));
  const box = el('div', 'stepper');
  const minus = el('button', '', '\u2212'), plus = el('button', '', '+');
  minus.addEventListener('click', () => update({ [key]: Math.max(min, s()[key] - 1) }));
  plus.addEventListener('click', () => update({ [key]: Math.min(max, s()[key] + 1) }));
  box.append(minus, plus);
  wrap.append(value, box);
  return wrap;
}

function section(...children) {
  const sec = el('div', 'section');
  sec.append(...children);
  return sec;
}

function caption(text, className = 'caption') { return el('div', className, text); }

// MARK: - Pages

const PAGES = {
  general: { title: 'General', icon: ICONS.gear },
  music: { title: 'Music', icon: ICONS.musicNote },
  claude: { title: 'Claude Code', icon: dotGrid(3) },
  pomodoro: { title: 'Pomodoro', icon: ICONS.timer },
  about: { title: 'About', icon: ICONS.circle },
};

function availablePages() {
  const pages = ['general'];
  if (s().effectiveMode !== 'claude') pages.push('music');
  if (s().effectiveMode !== 'music') pages.push('claude');
  pages.push('pomodoro', 'about');
  return pages;
}

function renderSidebar() {
  sidebar.replaceChildren();
  const groups = [['', ['general']], ['Features', availablePages().filter((p) => !['general', 'about'].includes(p))], ['About', ['about']]];
  for (const [title, pages] of groups) {
    if (title) sidebar.append(el('h2', '', title));
    for (const id of pages) {
      const b = el('button', `nav${page === id ? ' active' : ''}`);
      b.innerHTML = `${PAGES[id].icon}<span></span>`;
      b.lastChild.textContent = PAGES[id].title;
      b.addEventListener('click', () => { page = id; render(); });
      sidebar.append(b);
    }
  }
}

function generalPage() {
  const modeCaptions = {
    music: 'A Spotify island \u2014 now playing, controls, and a live waveform.',
    claude: 'A live status island for your Claude Code session.',
    both: 'Music and Claude Code, side by side.',
  };
  return [
    section(
      row('Isle shows', segmented('mode', [['music', 'Music'], ['claude', 'Claude Code'], ['both', 'Both']]), modeCaptions[s().effectiveMode]),
    ),
    section(
      row('Setup', (() => { const b = el('button', 'secondary', 'Run Setup\u2026'); b.addEventListener('click', () => window.isle.openSetup()); return b; })(),
        'Re-run the first-launch mode picker.'),
    ),
  ];
}

function musicPage() {
  const waveCaptions = {
    live: 'The bars move with the music. Captures system audio while Spotify plays \u2014 analysed in memory, never recorded. Other apps\u2019 sound moves the bars too while music is on.',
    animated: 'The bars move on their own whenever something is playing. Isle never listens.',
    off: 'No waveform. The island keeps its shape and shows just the album cover.',
  };
  return [
    section(
      row('Waveform', segmented('waveformSource', [['live', 'Live'], ['animated', 'Animated'], ['off', 'Off']]), waveCaptions[s().waveformSource]),
      row('Show scrubber', toggle('showScrubber')),
      row('Show shuffle & repeat', toggle('showShuffleRepeat')),
    ),
    section(caption('Playback is read and controlled through Windows\u2019 media session for Spotify \u2014 the same channel the keyboard media keys use. Nothing to sign in to.')),
  ];
}

function claudePage() {
  const installed = !!state.hookInstalled;
  const status = el('div', `hook-status ${installed ? 'ok' : ''}`);
  status.innerHTML = `${installed ? ICONS.checkCircle : ICONS.circle}<span></span>`;
  status.lastChild.textContent = installed ? 'Hook installed' : 'Hook not installed';
  if (!installed) status.style.color = 'var(--fg-55)';
  const action = el('button', `secondary${installed ? ' destructive' : ''}`, installed ? 'Remove' : 'Install');
  action.addEventListener('click', async () => {
    const result = installed ? await window.isle.uninstallHooks() : await window.isle.installHooks();
    hookMessage = result.message;
    render();
  });
  const hookRow = el('div', 'row'); hookRow.append(status, action);

  const swatches = el('div', 'swatches');
  for (const swatch of [...ACCENT_SWATCHES, 'custom']) {
    const b = el('button', `swatch${s().claudeAccent === swatch ? ' selected' : ''}`);
    b.title = ACCENT_TITLES[swatch];
    b.style.background = accentChip(swatch, s().claudeAccentHex);
    if (swatch === 'custom') {
      const input = document.createElement('input');
      input.type = 'color';
      input.value = s().claudeAccentHex || '#9438E0';
      input.addEventListener('input', () => update({ claudeAccent: 'custom', claudeAccentHex: input.value.toUpperCase() }));
      b.append(input);
    } else {
      b.addEventListener('click', () => update({ claudeAccent: swatch }));
    }
    swatches.append(b);
  }
  let accentCaption;
  if (s().claudeAccent === 'custom') {
    const clash = accentCollision(s().claudeAccentHex);
    accentCaption = clash
      ? `This is close to the colour Isle uses for ${clash}, so a working island may read as one. Still applied \u2014 it\u2019s your choice.`
      : 'A custom colour. Clear of the colours Isle uses for questions, errors and success.';
  } else if (s().claudeAccent === 'slate' || s().claudeAccent === 'stone') {
    accentCaption = `${ACCENT_TITLES[s().claudeAccent]} \u2014 muted rather than grey. A true grey can\u2019t be told apart from the disconnected state, which already uses it.`;
  } else {
    accentCaption = `${ACCENT_TITLES[s().claudeAccent] || 'Violet'}. Questions, errors and the done checkmark keep their own colours \u2014 those mean something.`;
  }
  if (s().effectiveMode === 'both') accentCaption += ' While music is playing the island takes its colour from the album art instead \u2014 this applies when nothing is.';

  const children = [hookRow];
  if (hookMessage) children.push(caption(hookMessage));
  return [
    section(...children),
    section(
      row('Accent', swatches, accentCaption),
      row('Keep \u201Cdone\u201D checkmark for', stepper('doneToastSeconds', 1, 15, (v) => `${Math.round(v)}s`)),
      row('Show \u201CWaiting\u201D in the island', toggle('showWaitingStatus'),
        s().showWaitingStatus ? 'The island shows when Claude has handed the turn back to you.' : 'Waiting stays out of the island; the expanded panel still shows it.'),
      row('Expand island for alerts', toggle('expandOnAlert'),
        s().expandOnAlert ? 'Questions and errors pop the island open.' : 'Delivered minimized \u2014 the collapsed island shows the alert; hover to open.'),
      row('Dismiss alert panel on hover-out / click', (() => { const t = toggle('dismissAlertPanel'); t.disabled = !s().expandOnAlert; return t; })(),
        s().dismissAlertPanel ? 'Hover away or click to retract the panel; the alert stays in the island until resolved.' : 'The panel stays open until the alert resolves (e.g. you answer).'),
    ),
  ];
}

function pomodoroPage() {
  const enabled = !!s().pomodoroEnabled;
  const parts = [
    row('Enable Pomodoro timer', toggle('pomodoroEnabled'),
      enabled ? 'A focus timer lives in the expanded panel; while it runs, the remaining time sits in the island.' : 'Off \u2014 the timer is hidden from the island entirely.'),
  ];
  if (enabled) {
    parts.push(
      row('Focus', stepper('pomodoroFocusMinutes', 1, 90, (v) => `${v} min`)),
      row('Short break', stepper('pomodoroShortBreakMinutes', 1, 30, (v) => `${v} min`)),
      row('Long break', stepper('pomodoroLongBreakMinutes', 1, 60, (v) => `${v} min`)),
      row('Focus sessions per cycle', stepper('pomodoroSessionsPerCycle', 1, 8, (v) => `${v}`)),
      row('Sound when an interval ends', toggle('pomodoroSound')),
      caption('Changes to the lengths apply from the next interval; the one that\u2019s running keeps its time.'),
    );
  }
  return [section(...parts)];
}

function aboutPage() {
  const link = el('button', 'secondary', 'Source on GitHub');
  link.addEventListener('click', () => window.isle.openExternal('https://github.com/matthewhamilton3141/isle'));
  return [
    section(
      row('Version', el('span', 'mono', state.version || '\u2014')),
      row('Isle for Windows', link, 'A Dynamic Island for the top of your screen \u2014 for Spotify, Claude Code and a Pomodoro timer. MIT licensed.'),
    ),
  ];
}

function render() {
  if (!state) return;
  if (!availablePages().includes(page)) page = 'general';
  renderSidebar();
  detail.replaceChildren(el('h1', '', PAGES[page].title));
  const content = { general: generalPage, music: musicPage, claude: claudePage, pomodoro: pomodoroPage, about: aboutPage }[page]();
  detail.append(...content);
}

window.isle.onState((next) => { state = next; render(); });
