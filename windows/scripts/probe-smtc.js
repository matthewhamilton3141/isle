// Quick manual probe of the SMTC bridge: prints a few snapshots, optionally
// sends a command, then quits. Usage: node scripts/probe-smtc.js [command...]
const { spawn } = require('child_process');
const path = require('path');

const script = path.join(__dirname, '..', 'src', 'main', 'media', 'smtc-bridge.ps1');
const ps = spawn(
  path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
  ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script],
  { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }
);

const started = Date.now();
let buffer = '';
ps.stdout.on('data', (chunk) => {
  buffer += chunk.toString('utf8');
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    const obj = JSON.parse(line);
    if (obj.art) obj.art = `<${obj.art.length} base64 chars>`;
    console.log(`+${((Date.now() - started) / 1000).toFixed(2)}s`, JSON.stringify(obj));
  }
});
ps.stderr.on('data', (d) => console.error('stderr:', d.toString()));
ps.on('exit', (code) => console.log('bridge exited', code));

const command = process.argv.slice(2).join(' ');
if (command) {
  setTimeout(() => { console.log('-> ' + command); ps.stdin.write(command + '\n'); }, 2500);
}
setTimeout(() => { ps.stdin.write('quit\n'); }, command ? 5500 : 4000);
