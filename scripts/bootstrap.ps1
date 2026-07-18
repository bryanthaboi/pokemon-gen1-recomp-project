# Windows double-click bootstrap for the LÖVE2D Pokémon Red port.
# Launched by Play-Windows.bat. Prompts to install any missing tools
# (Python 3 and LÖVE via winget), runs first-time setup, then
# starts the game. Later runs launch the game straight away.

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host " !! $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "error: $msg" -ForegroundColor Red }

function Pause-Exit([int]$code = 0) {
    Write-Host ''
    Read-Host 'Press Enter to close this window' | Out-Null
    exit $code
}

function Ask($question) { # yes by default
    $a = Read-Host "$question [Y/n]"
    return ($a -notmatch '^(n|no)$')
}

# winget installs update the registry PATH but not this process's copy;
# re-read it so freshly installed tools are usable without a new window.
function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Find-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try { if ((& py -3 --version 2>$null) -match '^Python 3') { return $true } } catch {}
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        try { if ((& python --version 2>$null) -match '^Python 3') { return $true } } catch {}
    }
    return $false
}

function Find-Love {
    foreach ($name in 'lovec', 'love') {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
    }
    foreach ($d in @("$env:ProgramFiles\LOVE", "${env:ProgramFiles(x86)}\LOVE", "$env:LOCALAPPDATA\Programs\LOVE")) {
        if ($d -and (Test-Path (Join-Path $d 'love.exe'))) { return $true }
    }
    return $false
}

Write-Host ''
Write-Host '  Pokemon Red - LOVE2D port' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- fast path
if ((Test-Path (Join-Path $Root 'data\generated\maps.lua')) -and (Find-Love)) {
    Say 'already set up - launching the game'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\run.ps1')
    if ($LASTEXITCODE -ne 0) { Err 'the game failed to start'; Pause-Exit 1 }
    exit 0
}

Say 'first-time setup'

# ------------------------------------------------------------------- winget
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Err 'winget (Windows package manager) is not available.'
    Warn 'Install "App Installer" from the Microsoft Store, then run this again.'
    Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' -ErrorAction SilentlyContinue
    Pause-Exit 1
}

# ------------------------------------------------------------------- python
if (-not (Find-Python)) {
    Warn 'Python 3 is missing (needed to build the game data)'
    if (Ask 'Install Python 3 now via winget?') {
        winget install --exact --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
        Refresh-Path
        if (-not (Find-Python)) {
            Err 'Python still not found after install - close this window and double-click again'
            Pause-Exit 1
        }
    } else { Err 'cannot continue without Python 3'; Pause-Exit 1 }
}

# --------------------------------------------------------------------- LOVE
if (-not (Find-Love)) {
    Warn 'LOVE (the game engine) is missing'
    if (Ask 'Install LOVE now via winget?') {
        winget install --exact --id Love2d.Love2d --accept-source-agreements --accept-package-agreements
        Refresh-Path
        if (-not (Find-Love)) {
            Err 'LOVE still not found after install - close this window and double-click again'
            Pause-Exit 1
        }
    } else { Err 'cannot continue without LOVE'; Pause-Exit 1 }
}

# -------------------------------------------------------------------- build
Write-Host ''
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\setup.ps1')
if ($LASTEXITCODE -ne 0) { Err 'setup failed - see the messages above'; Pause-Exit 1 }

Say 'setup done - launching the game'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\run.ps1')
if ($LASTEXITCODE -ne 0) { Err 'the game failed to start'; Pause-Exit 1 }
exit 0
