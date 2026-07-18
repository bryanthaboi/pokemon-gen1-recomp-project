# One-shot: full setup, then launch the game (Windows).
#
# Usage: powershell -ExecutionPolicy Bypass -File scripts\play.ps1 [-Rom red.gb]

param(
    [string]$Rom = $env:ROM_PATH
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'setup.ps1') -Rom $Rom
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot 'run.ps1')
exit $LASTEXITCODE
