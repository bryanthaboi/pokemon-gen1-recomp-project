# Build game data from a user-provided Pokemon Red ROM and install LÖVE.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Rom C:\path\red.gb
#
# With no explicit path, the first *.gb file in the project root is used.

param(
    [string]$Rom = $env:ROM_PATH
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Venv = Join-Path $Root '.venv'

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

function Find-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try {
            if ((& py -3 --version 2>$null) -match '^Python 3') {
                return @('py', '-3')
            }
        } catch {}
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        try {
            if ((& python --version 2>$null) -match '^Python 3') {
                return @('python')
            }
        } catch {}
    }
    return $null
}

$Python = @(Find-Python)
if (-not $Python) { Fail 'Python 3 is required to decode the ROM' }
$PyExe = $Python[0]
$PyArgs = @($Python | Select-Object -Skip 1)

if (-not $Rom) {
    $candidate = Get-ChildItem -Path $Root -Filter '*.gb' -File |
        Select-Object -First 1
    if ($candidate) { $Rom = $candidate.FullName }
}
if (-not $Rom -or -not (Test-Path -LiteralPath $Rom -PathType Leaf)) {
    Fail "Pokemon Red ROM not found. Put your .gb file in $Root or pass -Rom C:\path\red.gb"
}
$Rom = (Resolve-Path -LiteralPath $Rom).Path

$VenvPython = Join-Path $Venv 'Scripts\python.exe'
if (-not (Test-Path $VenvPython)) {
    Say 'creating Python environment'
    & $PyExe @PyArgs -m venv $Venv
    if ($LASTEXITCODE -ne 0) { Fail 'venv creation failed' }
}
Say 'installing Pillow'
& $VenvPython -m pip install --quiet --upgrade pip
& $VenvPython -m pip install --quiet pillow
if ($LASTEXITCODE -ne 0) { Fail 'Pillow installation failed' }

Say "decoding game data from $(Split-Path -Leaf $Rom)"
Push-Location $Root
try {
    & $VenvPython 'tools\build_data.py' --rom $Rom --clean
    if ($LASTEXITCODE -ne 0) { Fail 'ROM extraction failed' }
} finally {
    Pop-Location
}

function Find-Love {
    foreach ($name in 'lovec', 'love') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($dir in @(
        "$env:ProgramFiles\LOVE",
        "${env:ProgramFiles(x86)}\LOVE",
        "$env:LOCALAPPDATA\Programs\LOVE"
    )) {
        if ($dir) {
            $candidate = Join-Path $dir 'love.exe'
            if (Test-Path $candidate) { return $candidate }
        }
    }
    return $null
}

if (Find-Love) {
    Say 'LÖVE found'
} elseif (Get-Command winget -ErrorAction SilentlyContinue) {
    Say 'installing LÖVE via winget'
    winget install --exact --id Love2d.Love2d --accept-source-agreements --accept-package-agreements
} else {
    Fail 'LÖVE 11.x is not installed; install it from https://love2d.org'
}

Say 'setup complete. Start the game with: scripts\run.ps1'
exit 0
