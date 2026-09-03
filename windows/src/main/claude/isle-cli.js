#!/usr/bin/env node
//
// isle-cli — the bridge script Claude Code's hooks call on Windows. Writes one
// small JSON status file per session (~/.isle/sessions/<session-id>.json) that
// Isle watches. A port of the Mac app's bash helper; kept dependency-free (just
// Node) so a missing tool can never break a hook, and it does NOT require Isle
// to be running — it only writes a file, and exits 0 either way.
//
// Usage:
//   isle-cli set-state <idle|working|done|compacting|...>   # state from the hook
//   isle-cli notify                                          # classify a Notification
//   isle-cli ask                                             # permission → a question
//   isle-cli fail                                            # StopFailure → error
//   isle-cli end                                             # session ended — clear
//
// The hook payload arrives as JSON on stdin. Installed by HookInstaller into
// ~/.isle/bin; `integration/isle-cli.js` is the same file for manual installs.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const SESSION_DIR = path.join(os.homedir(), '.isle', 'sessions');

function readStdin() {
  try {
    if (process.stdin.isTTY) return '';
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

/** Parses the payload, falling back to a tolerant field scrape if it isn't JSON. */
function parsePayload(text) {
  if (!text.trim()) return {};
  try { return JSON.parse(text); } catch { /* fall through */ }
  const scraped = {};
  for (const key of ['hook_event_name', 'session_id', 'tool_name', 'message', 'last_assistant_message', 'error_type', 'error']) {
    const match = new RegExp(`"${key}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"`).exec(text);
    if (match) scraped[key] = match[1];
  }
  return scraped;
}

function str(value) { return typeof value === 'string' ? value : ''; }

/** A best-effort target for the tool: file path, command, pattern, URL. */
function pickTarget(input) {
  if (!input || typeof input !== 'object') return '';
  for (const key of ['file_path', 'command', 'pattern', 'path', 'url', 'notebook_path']) {
    if (typeof input[key] === 'string' && input[key]) return input[key];
  }
  return '';
}

function reduceTarget(raw) {
  let target = str(raw).replace(/\\/g, '/');
  // Reduce a bare file path to its last component. URLs (host matters) and
  // command lines (first token matters) are left for the app to reduce.
  if (!target.includes('://') && !target.includes(' ') && target.includes('/')) {
    target = target.slice(target.lastIndexOf('/') + 1);
  }
  return target.slice(0, 48);
}

function sessionFile(sessionId) {
  const safe = (sessionId || 'unknown').replace(/[^A-Za-z0-9._-]/g, '_');
  return path.join(SESSION_DIR, `${safe}.json`);
}

// Written to a temp file and renamed into place, never edited in place, so
// Isle can never read a half-written record.
function writeStatus(state, fields) {
  fs.mkdirSync(SESSION_DIR, { recursive: true });
  const file = sessionFile(fields.sessionId);
  const tmp = `${file}.tmp.${process.pid}`;
  const record = {
    state,
    project: fields.project,
    session_id: fields.sessionId,
    action: fields.action,
    target: fields.target,
    error_type: fields.errorType,
    tool_active: fields.toolActive,
    reset_at: fields.resetAt,
    request_id: '',
    updated_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
  };
  fs.writeFileSync(tmp, JSON.stringify(record, null, 2));
  fs.renameSync(tmp, file);
}

function main(argv) {
  const cmd = argv[0] || '';
  let state = '';
  switch (cmd) {
    case 'set-state':
      state = argv[1] || '';
      if (!state) {
        process.stderr.write('Usage: isle-cli set-state <state>\n');
        return 1;
      }
      break;
    case 'notify': case 'ask': state = ''; break;
    case 'fail': state = 'error'; break;
    case 'end': state = 'disconnected'; break;
    default:
      process.stderr.write('Usage: isle-cli <set-state <state> | notify | fail | ask | end>\n');
      return 1;
  }

  const payload = parsePayload(readStdin());
  const hookEvent = str(payload.hook_event_name);
  const sessionId = str(payload.session_id);
  const action = str(payload.tool_name);
  const target = reduceTarget(pickTarget(payload.tool_input));
  const message = str(payload.message);
  const lastMessage = str(payload.last_assistant_message);
  let errorType = str(payload.error_type);
  // StopFailure names the failure `error`, not `error_type`. Gated to `fail`
  // so a tool payload carrying an "error" key can't stamp a kind onto a
  // non-failure write.
  if (!errorType && cmd === 'fail') errorType = str(payload.error);
  const project = path.basename(str(payload.cwd) || process.cwd());
  // True only between a PreToolUse and its PostToolUse.
  const toolActive = hookEvent === 'PreToolUse';
  let resetAt = '';

  const fields = { project, sessionId, action, target, errorType, toolActive, resetAt };

  // `ask` (PermissionRequest hook): surface a question, never block.
  if (cmd === 'ask') {
    writeStatus('needs_question', fields);
    return 0;
  }

  if (cmd === 'notify') {
    // Keep an active question: the notification that follows an
    // AskUserQuestion is just "waiting on you" for the same prompt.
    try {
      const current = fs.readFileSync(sessionFile(sessionId), 'utf8');
      if (/"state":\s*"needs_question"/.test(current)) return 0;
    } catch { /* no record yet */ }
    state = message.toLowerCase().includes('waiting') ? 'waiting_input' : 'needs_question';
  }

  // A tool that asks the user a question surfaces as a question — but only
  // while it's being asked (PreToolUse), not when its PostToolUse fires.
  if (cmd === 'set-state' && state === 'working' && action === 'AskUserQuestion' && hookEvent !== 'PostToolUse') {
    state = 'needs_question';
  }

  // The usage/subscription limit is distinct from a transient API error.
  if (cmd === 'fail' || cmd === 'notify') {
    const all = `${errorType} ${message} ${lastMessage}`.toLowerCase();
    if (/usage.*limit|limit.*reached|quota|hit your.*limit/.test(all)) {
      state = 'error';
      fields.errorType = 'usage_limit';
    }
  }

  if (fields.errorType === 'usage_limit') {
    const epoch = /\b(\d{10,13})\b/.exec(`${message} ${lastMessage}`);
    fields.resetAt = epoch ? epoch[1] : '';
  }

  // `end` (SessionEnd): drop this session's file and stop.
  if (cmd === 'end') {
    try { fs.unlinkSync(sessionFile(sessionId)); } catch { /* already gone */ }
    return 0;
  }

  writeStatus(state, fields);
  return 0;
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (error) {
  // A hook must never fail loudly: a non-zero exit shows up in the Claude
  // session as a hook error. Report on stderr and exit clean.
  process.stderr.write(`isle-cli: ${error && error.message}\n`);
  process.exitCode = 0;
}
