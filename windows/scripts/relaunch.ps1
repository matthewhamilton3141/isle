# Dev helper: kill any running Isle, relaunch it detached with logs in %TEMP%.
param([switch]$Dev)
Get-Process electron -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
$root = Split-Path $PSScriptRoot -Parent
$args = @('.')
if ($Dev) { $args += '--dev' }
Start-Process -FilePath (Join-Path $root 'node_modules\.bin\electron.cmd') -ArgumentList $args -WorkingDirectory $root `
  -RedirectStandardOutput "$env:TEMP\isle-out.log" -RedirectStandardError "$env:TEMP\isle-err.log" -WindowStyle Hidden
Start-Sleep -Seconds 5
"--- stdout ---"; Get-Content "$env:TEMP\isle-out.log" -ErrorAction SilentlyContinue
"--- stderr ---"; Get-Content "$env:TEMP\isle-err.log" -ErrorAction SilentlyContinue | Select-Object -First 30
