# Isle for Windows — notes for agents

- Run: `cd windows && npm install && npm start` (Electron 43, no build step).
- If the shell has `ELECTRON_RUN_AS_NODE=1` (editor-integrated terminals often
  do), Electron runs as plain Node and no window appears. Unset it first:
  `Remove-Item Env:ELECTRON_RUN_AS_NODE`. `scripts/relaunch.ps1` does this.
- Do not pipe `scripts/relaunch.ps1`'s output (`| Out-Null`, `| Select-Object`);
  the detached Electron child holds the pipe open and the call never returns.
- Visual checks: `scripts/screenshot.ps1 out.png x y w h scale`, then read the
  PNG. Verify hover and click interactions manually.
- Renderer `console.warn`/`error` show in `%TEMP%\isle-out.log` after
  `relaunch.ps1`; `-Dev` echoes everything and opens DevTools.
- The SMTC bridge runs under Windows PowerShell 5.1 (.NET Framework). See the
  README's "How the platform layer works" for the three quirks to avoid.
- Preferences live in `%APPDATA%\Isle\settings.json`; delete `mode` to see the
  first-launch Setup again.
- `src/main/claude/isle-cli.js` and `integration/isle-cli.js` must stay
  identical (the installer copies the former; the latter is for manual use).
