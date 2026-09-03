// onboarding.js
//
// First-run picker. Asks what the user wants Isle to be — Music, Claude
// Code, or Both — then whether the waveform should listen, then (for
// Claude/Both) offers to install the hook. The mode is written last: on a
// first launch the island doesn't start until a mode exists.

import { ICONS } from '../shared/icons.js';

const root = document.getElementById('root');
let settings = null;
let hookInstalled = false;
let step = 'pickMode';
let selection = 'both';
let liveWaveform = true;
let hookMessage = null;

const MODES = [
  { id: 'music', title: 'Music', icon: ICONS.musicNote,
    subtitle: 'A Spotify island — now playing, controls, and a live waveform.',
    consequence: 'Reads and controls Spotify through Windows\u2019 media session. Listening for the waveform is a separate choice, next.' },
  { id: 'claude', title: 'Claude Code', icon: ICONS.sparkle,
    subtitle: 'A live status island for your Claude Code session.',
    consequence: 'Adds a hook to your Claude Code settings. No media access.' },
  { id: 'both', title: 'Both', icon: ICONS.split,
    subtitle: 'Music and Claude Code, side by side.',
    consequence: 'Spotify control plus the Claude Code hook. Listening for the waveform is a separate choice, next.' },
];

function card({ icon, title, subtitle, consequence, selected, indicator, onClick }) {
  const button = document.createElement('button');
  button.className = `card${selected ? ' selected' : ''}`;
  button.innerHTML = `<span class="icon">${icon}</span><span class="text"><span class="title"></span><span class="subtitle"></span><span class="consequence"></span></span><span class="indicator">${indicator}</span>`;
  button.querySelector('.title').textContent = title;
  button.querySelector('.subtitle').textContent = subtitle;
  button.querySelector('.consequence').textContent = consequence;
  button.addEventListener('click', onClick);
  return button;
}

function header(title, lede) {
  const wrap = document.createElement('div');
  wrap.innerHTML = `<h1></h1><div class="lede"></div>`;
  wrap.querySelector('h1').textContent = title;
  wrap.querySelector('.lede').textContent = lede;
  return wrap;
}

function buttons(left, right) {
  const row = document.createElement('div');
  row.className = 'button-row';
  row.append(left || document.createElement('span'), right);
  return row;
}

function primary(label, onClick) {
  const b = document.createElement('button'); b.className = 'primary'; b.textContent = label; b.addEventListener('click', onClick); return b;
}
function plain(label, onClick) {
  const b = document.createElement('button'); b.className = 'plain'; b.textContent = label; b.addEventListener('click', onClick); return b;
}

function render() {
  root.replaceChildren();
  if (step === 'pickMode') {
    root.append(header('Welcome to Isle', 'A Dynamic Island for the top of your screen. What should it do?'));
    const cards = document.createElement('div'); cards.className = 'cards';
    for (const mode of MODES) {
      cards.append(card({
        ...mode, selected: selection === mode.id,
        indicator: selection === mode.id ? ICONS.checkCircle : ICONS.circle,
        onClick: () => { selection = mode.id; render(); },
      }));
    }
    root.append(cards, buttons(null, primary('Continue', () => { step = 'extras'; render(); })));
  } else if (step === 'extras') {
    root.append(header('What Isle may listen to', 'One choice here, so Isle only captures what you actually want.'));
    const cards = document.createElement('div'); cards.className = 'cards';
    if (selection !== 'claude') {
      cards.append(card({
        icon: ICONS.waveform, title: 'Live waveform',
        subtitle: 'The bars in the island move with the music.',
        consequence: 'Captures Windows\u2019 system audio while Spotify is playing, analysed in memory and never recorded. Unticked, the waveform still animates \u2014 it just doesn\u2019t listen.',
        selected: liveWaveform, indicator: liveWaveform ? ICONS.checkSquare : ICONS.square,
        onClick: () => { liveWaveform = !liveWaveform; render(); },
      }));
    } else {
      const note = document.createElement('div'); note.className = 'caption'; note.style.marginTop = '24px';
      note.textContent = 'A Claude-only island needs nothing from the system beyond the hook. Continue.';
      cards.append(note);
    }
    const fine = document.createElement('div'); fine.className = 'fine'; fine.style.marginTop = '14px';
    fine.textContent = 'All of this can be changed any time in Settings.';
    root.append(cards, fine, buttons(plain('Back', () => { step = 'pickMode'; render(); }), primary('Continue', advanceFromExtras)));
  } else {
    root.append(header('Connect Claude Code', 'Isle watches a small status file that Claude Code\u2019s hooks write. Installing the hook sets that up.'));
    const details = document.createElement('div'); details.className = 'details';
    for (const text of [
      'Drops the isle-cli helper into ~/.isle/bin.',
      'Merges hook entries into ~/.claude/settings.json \u2014 your existing hooks are left alone.',
      'Removable any time from Settings.',
    ]) { const d = document.createElement('div'); d.className = 'detail'; d.textContent = text; details.append(d); }
    root.append(details);
    if (hookInstalled) {
      const s = document.createElement('div'); s.className = 'status ok'; s.innerHTML = `${ICONS.checkCircle}<span>Hook installed</span>`; root.append(s);
    } else if (hookMessage) {
      const s = document.createElement('div'); s.className = 'status warn'; s.innerHTML = `${ICONS.warning}<span></span>`; s.lastChild.textContent = hookMessage; root.append(s);
    }
    root.append(buttons(
      plain('Skip for now', finish),
      hookInstalled ? primary('Done', finish) : primary('Install hook', installHook),
    ));
  }
}

function advanceFromExtras() {
  const partial = { mode: selection };
  if (selection !== 'claude' && settings) {
    const currentlyLive = settings.waveformSource === 'live';
    if (liveWaveform !== currentlyLive) partial.waveformSource = liveWaveform ? 'live' : 'animated';
  }
  window.isle.updateSettings(partial);
  if (selection !== 'music') { step = 'connectClaude'; render(); } else finish();
}

async function installHook() {
  const result = await window.isle.installHooks();
  hookInstalled = result.ok;
  hookMessage = result.ok ? null : result.message;
  render();
}

function finish() { window.isle.closeWindow(); }

window.isle.onState((state) => {
  const first = settings == null;
  settings = state.settings;
  hookInstalled = !!state.hookInstalled;
  if (first) {
    // Re-opened from the tray, the screen starts from what's already chosen.
    if (settings.hasChosenMode) selection = settings.effectiveMode;
    liveWaveform = settings.hasChosenMode ? settings.waveformSource === 'live' : true;
    render();
  }
});
render();
