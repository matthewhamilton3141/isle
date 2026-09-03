// view-model.js
//
// Everything the island derives from its inputs — a port of the derived half
// of NotchViewModel plus IslandPresentation's alert bookkeeping. Pure
// functions of (settings, claude, pomodoro, media, hover) so the renderer
// can recompute on every change and lay out from the result.

import { FALLBACK_PALETTE, accentPalette } from '../shared/colors.js';
import { markerKind } from '../shared/markers.js';

/** Element widths for the collapsed island, shared by the width calculation
 *  and the layout so they can't drift. */
export const COLLAPSED = Object.freeze({
  album: 22,
  wave: 20,
  dots: 16,
  gap: 8,          // between elements within a cluster
  cutoutGap: 8,    // between a cluster and the cutout
  minSide: 30,     // resting half-width when a side is empty
  statusFontSize: 10,
  hPadding: 28,    // 10 (root) + 4 (collapsed view), each side
});

const ATTENTION = new Set(['needsApproval', 'needsQuestion']);

/** Turns a tool call into the "what it's doing" line (ClaudeActivity.swift). */
export function activityPhrase(action, target) {
  if (!action) return null;
  const t = target && target.length ? target : null;
  const last = (p) => { const s = p.replace(/\\/g, '/'); const i = s.lastIndexOf('/'); return i >= 0 && i < s.length - 1 ? s.slice(i + 1) : s; };
  const host = (s) => { try { const h = new URL(s).host; return h.startsWith('www.') ? h.slice(4) : h; } catch { return null; } };
  switch (action) {
    case 'Edit': case 'MultiEdit': case 'Write': case 'NotebookEdit':
      return `Editing ${t ? last(t) : 'a file'}`;
    case 'Read':
      return `Reading ${t ? last(t) : 'a file'}`;
    case 'Bash': case 'BashOutput': case 'KillShell': {
      const token = t ? t.split(' ')[0] : null;
      return token ? `Running ${last(token)}` : 'Running a command';
    }
    case 'Grep': case 'Glob':
      return t ? `Searching \u201C${t}\u201D` : 'Searching';
    case 'WebFetch': case 'WebSearch':
      return t ? `Browsing ${host(t) || t}` : 'Browsing the web';
    case 'Task': case 'Agent':
      return 'Delegating a task';
    case 'TodoWrite':
      return 'Updating the plan';
    default:
      return t ? `${action} ${t}` : action;
  }
}

export function clockString(seconds) {
  const total = Math.ceil(Math.max(0, seconds));
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  const pad = (n) => String(n).padStart(2, '0');
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

export function timeString(seconds) {
  const total = Math.floor(Math.max(0, seconds));
  const m = Math.floor(total / 60), s = total % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

/**
 * @param {object} input
 * @param {object} input.settings   settings snapshot from main
 * @param {object} input.claude     claude snapshot from main
 * @param {object} input.pomodoro   pomodoro snapshot from main
 * @param {object} input.media      MediaModel.media
 * @param {object|null} input.artworkPalette
 * @param {(text: string, font: 'status'|'clock') => number} input.measure
 * @param {object} input.alert      { dismissed, tabOverridden }
 * @param {string} input.activeTab  the user's last pick
 */
export function derive(input) {
  const { settings, claude, pomodoro, media, artworkPalette, measure, alert, activeTab } = input;
  const mode = settings.effectiveMode || 'both';
  const showsMusic = mode !== 'claude';
  const showsClaude = mode !== 'music';

  const palette = artworkPalette
    || (settings.claudeAccent ? accentPalette(settings.claudeAccent, settings.claudeAccentHex) : FALLBACK_PALETTE);

  const state = showsClaude ? claude.state : 'disconnected';
  const isUsageLimit = state === 'failed' && claude.errorType === 'usage_limit';
  const hasLiveActivity = showsClaude && (ATTENTION.has(state) || (state === 'failed' && !isUsageLimit));
  const autoExpandsForActivity = hasLiveActivity && !!settings.expandOnAlert && !alert.dismissed;

  const hasMusicActivity = showsMusic && !!media.hasTrack;
  const hasClaudeActivity = showsClaude && state !== 'disconnected' && state !== 'idle'
    && (state !== 'waitingInput' || !!settings.showWaitingStatus);
  const pomodoroAvailable = !!settings.pomodoroEnabled;
  const hasPomodoroActivity = pomodoroAvailable && !!pomodoro.isActive;

  const isClaudeSolo = hasClaudeActivity && !hasMusicActivity;
  const isPomodoroSolo = hasPomodoroActivity && !hasMusicActivity && !hasClaudeActivity;
  const shouldSplitCollapsed = hasMusicActivity && (hasClaudeActivity || hasPomodoroActivity);
  const pomodoroOnTrailingSide = hasPomodoroActivity && !isPomodoroSolo;
  const isCollapsedIdle = !hasMusicActivity && !hasClaudeActivity && !hasPomodoroActivity;

  const activity = activityPhrase(claude.action, claude.target);
  const isThinking = state === 'working' && !activity;
  const workingWord = claude.workingWord || 'Working';

  let collapsedStatusText = '';
  switch (state) {
    case 'working': collapsedStatusText = (isThinking ? 'Thinking' : workingWord) + '\u2026'; break;
    case 'needsApproval': case 'needsQuestion': collapsedStatusText = 'Question'; break;
    case 'waitingInput': collapsedStatusText = 'Waiting'; break;
    case 'done': collapsedStatusText = 'Done'; break;
    case 'idle': collapsedStatusText = 'Ready'; break;
    case 'failed': collapsedStatusText = 'Error'; break;
    case 'compacting': collapsedStatusText = 'Compacting'; break;
    default: collapsedStatusText = '';
  }

  // The warm working tint in the Claude-solo island: the paler stop while
  // thinking, the fuller one once a tool is running.
  const workingTint = isClaudeSolo && state === 'working' ? (isThinking ? palette.accent : palette.primary) : null;

  // Width reserved for the collapsed clock, from a template shaped by the
  // interval's full length so the island never jitters as digits count down.
  const phaseDuration = Number.isFinite(pomodoro && pomodoro.phaseDuration) ? pomodoro.phaseDuration : 1500;
  const template = phaseDuration >= 3600 ? '0:00:00' : phaseDuration >= 600 ? '00:00' : '0:00';
  const measuredClock = Math.max(0, Number.isFinite(measure(template, 'clock')) ? measure(template, 'clock') : 30);
  const pomodoroClockWidth = measuredClock + 2;

  const c = COLLAPSED;
  const g = c.cutoutGap;
  const waveSlot = c.gap + c.wave;
  const pomodoroSlot = c.dots + c.gap + pomodoroClockWidth;
  const statusWidth = collapsedStatusText ? measure(collapsedStatusText, 'status') : 0;
  const statusSlot = statusWidth > 0 ? c.gap + statusWidth : 0;

  let sides;
  if (shouldSplitCollapsed) {
    let trailing = c.wave + g;
    if (hasClaudeActivity) trailing += c.gap + c.dots + statusSlot;
    if (pomodoroOnTrailingSide) trailing += c.gap + pomodoroSlot;
    sides = { leading: c.album + g, trailing };
  } else if (hasClaudeActivity) {
    let trailing = statusWidth;
    if (pomodoroOnTrailingSide) trailing += (trailing > 0 ? c.gap : 0) + pomodoroSlot;
    sides = { leading: c.album + g, trailing: trailing > 0 ? trailing + g : c.minSide };
  } else if (hasPomodoroActivity) {
    sides = { leading: c.album + g, trailing: pomodoroClockWidth + g };
  } else if (hasMusicActivity) {
    sides = { leading: c.album + g, trailing: c.wave + g };
  } else {
    sides = { leading: c.minSide, trailing: c.minSide };
  }

  const tabs = [];
  if (showsMusic) tabs.push('music');
  if (showsClaude) tabs.push('claude');
  if (pomodoroAvailable) tabs.push('pomodoro');
  let expandedTab;
  if (hasLiveActivity && !alert.tabOverridden && tabs.includes('claude')) expandedTab = 'claude';
  else if (tabs.includes(activeTab)) expandedTab = activeTab;
  else expandedTab = tabs[0] || 'music';

  return {
    mode, showsMusic, showsClaude, palette,
    claudeState: state, isUsageLimit, hasLiveActivity, autoExpandsForActivity,
    hasMusicActivity, hasClaudeActivity, hasPomodoroActivity, pomodoroAvailable,
    isClaudeSolo, isPomodoroSolo, shouldSplitCollapsed, pomodoroOnTrailingSide, isCollapsedIdle,
    activity, isThinking, workingWord, collapsedStatusText, workingTint,
    markerKind: markerKind(state, claude.errorType),
    pomodoroClockWidth, sides,
    availableTabs: tabs, showsTabBar: tabs.length > 1, expandedTab,
    showsWaveform: settings.waveformSource !== 'off',
    listens: settings.waveformSource === 'live',
    showScrubber: !!settings.showScrubber,
    showShuffleRepeat: !!settings.showShuffleRepeat,
    sessionsPerCycle: Math.max(1, settings.pomodoroSessionsPerCycle || 1),
  };
}
