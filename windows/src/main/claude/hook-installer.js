// hook-installer.js
//
// Installs the Claude Code side of the bridge so the user doesn't have to
// hand-edit ~/.claude/settings.json. Drops the `isle-cli.js` helper into
// ~/.isle/bin and merges the hook events into the user's Claude Code settings,
// referencing the helper by absolute path.
//
// Windows wrinkle: Claude Code runs hook commands through Git Bash when it is
// installed and through cmd.exe otherwise, so the command has to parse the
// same way in both. `"<node.exe>" "<isle-cli.js>" args` does — forward slashes
// are accepted by both shells inside quotes. When no node.exe is on PATH the
// command points at Isle's own executable with `--isle-cli`, which main.js
// intercepts before any window is created (see runCliIfRequested).
//
// The merge is additive and reversible: existing hooks are preserved, and
// uninstall removes only the entries that point at our helper.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK_EVENTS = [
  ['UserPromptSubmit', 'set-state working'],
  ['PreToolUse', 'set-state working'],
  ['PermissionRequest', 'ask'],
  ['PostToolUse', 'set-state working'],
  ['Notification', 'notify'],
  ['Stop', 'set-state done'],
  ['StopFailure', 'fail'],
  ['PreCompact', 'set-state compacting'],
  ['SessionStart', 'set-state idle'],
  ['SessionEnd', 'end'],
];

// Bumped whenever the helper or the hook set changes, so an install from an
// older Isle refreshes itself on next launch.
const CURRENT_VERSION = 1;

const home = os.homedir();
const binDir = path.join(home, '.isle', 'bin');
const scriptPath = path.join(binDir, 'isle-cli.js');
const claudeSettingsPath = path.join(home, '.claude', 'settings.json');
const sourceScript = path.join(__dirname, 'isle-cli.js');

/** Forward-slashed, quoted — the one spelling both bash and cmd accept. */
function quote(p) { return `"${p.replace(/\\/g, '/')}"`; }

function findNode() {
  try {
    const out = execFileSync('where.exe', ['node.exe'], { encoding: 'utf8', windowsHide: true });
    const first = out.split(/\r?\n/).map((s) => s.trim()).find(Boolean);
    if (first && fs.existsSync(first)) return first;
  } catch { /* not on PATH */ }
  return null;
}

/**
 * The command prefix hooks invoke. `launcher` describes how to reach Isle's
 * own binary when node isn't available: { exe, appPath|null }.
 */
function commandPrefix(launcher) {
  const node = findNode();
  if (node) return `${quote(node)} ${quote(scriptPath)}`;
  const parts = [quote(launcher.exe)];
  if (launcher.appPath) parts.push(quote(launcher.appPath));
  parts.push('--isle-cli');
  return parts.join(' ');
}

/** Whether a hook command is one of ours, whichever launcher wrote it. */
function isIsleCommand(command) {
  return typeof command === 'string'
    && (command.includes('isle-cli.js') || command.includes('--isle-cli'));
}

function refersToIsle(group) {
  const inner = group && Array.isArray(group.hooks) ? group.hooks : [];
  return inner.some((h) => h && isIsleCommand(h.command));
}

function readSettings() {
  if (!fs.existsSync(claudeSettingsPath)) return {};
  const raw = fs.readFileSync(claudeSettingsPath, 'utf8');
  if (!raw.trim()) return {};
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error("Couldn't read ~/.claude/settings.json: not a JSON object");
  }
  return parsed;
}

function writeSettings(root) {
  fs.mkdirSync(path.dirname(claudeSettingsPath), { recursive: true });
  const tmp = `${claudeSettingsPath}.isle-tmp`;
  fs.writeFileSync(tmp, JSON.stringify(root, null, 2) + '\n');
  fs.renameSync(tmp, claudeSettingsPath);
}

function settingsReferenceIsle() {
  try {
    const root = readSettings();
    const hooks = root.hooks && typeof root.hooks === 'object' ? root.hooks : {};
    return Object.values(hooks).some((groups) => Array.isArray(groups) && groups.some(refersToIsle));
  } catch {
    return false;
  }
}

function isInstalled() {
  return fs.existsSync(scriptPath) && settingsReferenceIsle();
}

function install(launcher) {
  fs.mkdirSync(binDir, { recursive: true });
  fs.copyFileSync(sourceScript, scriptPath);

  const root = readSettings();
  const hooks = root.hooks && typeof root.hooks === 'object' ? root.hooks : {};
  const prefix = commandPrefix(launcher);
  for (const [event, args] of HOOK_EVENTS) {
    // Drop any prior Isle entry for this event first, so re-installing
    // replaces it rather than stacking a duplicate.
    const groups = (Array.isArray(hooks[event]) ? hooks[event] : []).filter((g) => !refersToIsle(g));
    groups.push({ hooks: [{ type: 'command', command: `${prefix} ${args}` }] });
    hooks[event] = groups;
  }
  root.hooks = hooks;
  writeSettings(root);
}

function uninstall() {
  const root = readSettings();
  if (root.hooks && typeof root.hooks === 'object') {
    for (const [event, groups] of Object.entries(root.hooks)) {
      if (!Array.isArray(groups)) continue;
      const kept = groups.filter((g) => !refersToIsle(g));
      if (kept.length) root.hooks[event] = kept; else delete root.hooks[event];
    }
    if (!Object.keys(root.hooks).length) delete root.hooks;
    writeSettings(root);
  }
  try { fs.unlinkSync(scriptPath); } catch { /* already gone */ }
}

/** Re-applies an older install on launch. No-op when not installed or current. */
function refreshIfNeeded(settings, launcher) {
  if (!isInstalled()) return;
  if ((settings.get('hookInstalledVersion') || 0) >= CURRENT_VERSION) return;
  try {
    install(launcher);
    settings.update({ hookInstalledVersion: CURRENT_VERSION });
  } catch (error) {
    console.warn('[hooks] refresh failed:', error.message);
  }
}

module.exports = {
  install, uninstall, isInstalled, refreshIfNeeded, CURRENT_VERSION,
  paths: { binDir, scriptPath, claudeSettingsPath },
};
