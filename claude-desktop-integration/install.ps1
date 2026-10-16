<#
.SYNOPSIS
  Wire up the Claude Desktop (third-party inference) integration on Windows.

.DESCRIPTION
  Windows port of install.sh, which lives beside this file. Runs entirely in
  place: it checks prerequisites, starts the desktop proxy on :4002 and prints
  the exact values to paste into Claude Desktop. It does NOT touch the
  zim-claude CLI proxy on :4000, does not copy anything into .local\bin, and
  does not touch your shell config.

  Managed settings are Linux-only (they are written to
  /etc/claude-desktop/managed-settings.json with sudo). Windows has no
  equivalent file, so here the values go in through the app's dialog - this
  script prints them at the end.

.PARAMETER NoStart
  Do everything except starting the proxy. Start later with:
  .\start-desktop-proxy.cmd start

.PARAMETER Managed
  Accepted for CLI parity with install.sh, but refused: managed settings have
  no Windows equivalent. Use the in-app dialog instead.

.PARAMETER UninstallManaged
  Same refusal as -Managed.

.PARAMETER Help
  Show this help.

.EXAMPLE
  .\install.cmd
  .\install.cmd -NoStart
#>

[CmdletBinding()]
param(
  [switch]$NoStart,
  [switch]$Managed,
  [switch]$UninstallManaged,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Say  { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red }

# --- help ---------------------------------------------------------------------
if ($Help) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# --- the managed-settings route is Linux-only ---------------------------------
# The no-click route writes /etc/claude-desktop/managed-settings.json with
# sudo. Windows has no equivalent location Claude Desktop reads, so refusing
# beats pretending: the app dialog below is the only route here.
if ($Managed -or $UninstallManaged) {
  Write-Err "managed settings are not available on Windows."
  Write-Err "  install.sh --managed writes /etc/claude-desktop/managed-settings.json,"
  Write-Err "  which has no Windows equivalent. Use the in-app dialog instead -"
  Write-Err "  this script prints the exact values to paste at the end."
  exit 2
}

# --- 1. prerequisites ---------------------------------------------------------
Write-Say "checking prerequisites"

# Same resolution order as start-desktop-proxy.ps1.
$LitellmBin = $null
$cmd = Get-Command litellm -ErrorAction SilentlyContinue
if ($cmd) { $LitellmBin = $cmd.Source }
if (-not $LitellmBin) {
  $candidates = @(
    (Join-Path $env:APPDATA 'Python\Scripts\litellm.exe'),
    (Join-Path $env:USERPROFILE '.local\bin\litellm.exe'),
    (Join-Path $env:USERPROFILE '.local\share\zim-claude\venv\Scripts\litellm.exe')
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $LitellmBin = $c; break } }
}
if (-not $LitellmBin -and (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Python'))) {
  $found = Get-ChildItem -Path (Join-Path $env:APPDATA 'Python') -Filter 'litellm.exe' `
           -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { $LitellmBin = $found.FullName }
}
if (-not $LitellmBin) {
  Write-Err "litellm not found."
  Write-Err "  Run windows\win-install.bat first (installs litellm via pip --user), or:"
  Write-Err "    python -m pip install --user `"litellm[proxy]`""
  exit 1
}
Write-Ok "litellm: $LitellmBin"

# LiteLLM >= 1.100.1 is a hard floor (see the README): older versions only
# serve /v1/messages to anthropic/*-registered models, and this gateway
# registers openai/* - a proxy that looks healthy and fails every request.
# Best effort: a version that cannot be parsed is reported, not fatal.
try {
  $vline = (& $LitellmBin --version 2>$null | Out-String)
  if ($vline -match '(\d+\.\d+\.\d+)') {
    $v = [version]$Matches[1]
    if ($v -lt [version]'1.100.1') {
      Write-Warn "litellm $v is older than the required 1.100.1 - /v1/messages would 500."
      Write-Warn "  upgrade with: python -m pip install --user --upgrade `"litellm[proxy]>=1.100.1`""
    }
  }
} catch { }

$StateDir = Join-Path $env:USERPROFILE '.local\share\zim-claude'
if ($env:LITELLM_ENV_FILE) { $EnvFile = $env:LITELLM_ENV_FILE }
else { $EnvFile = Join-Path $env:USERPROFILE 'claude-source\deepseek-claude' }

if (-not (Test-Path -LiteralPath $EnvFile)) {
  Write-Err "env profile missing: $EnvFile"
  Write-Err "  It holds the upstream token. Run windows\win-install.bat first (creates it"
  Write-Err "  from config\token), or set LITELLM_ENV_FILE to an existing profile."
  exit 1
}
Write-Ok "profile: $EnvFile"

$Config = Join-Path $Dir 'litellm-config.desktop.yaml'
if (-not (Test-Path -LiteralPath $Config)) {
  Write-Err "missing $Config"; exit 1
}
Write-Ok "config:  $Config"

# Advisory only: the config stays valid wherever the app is installed.
$deskExe = @(
  (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'),
  (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Claude.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($deskExe) {
  Write-Ok "claude-desktop: $deskExe"
} else {
  Write-Warn "Claude Desktop not found under %LOCALAPPDATA%\AnthropicClaude."
  Write-Warn "  The config below is still valid if the app is installed elsewhere."
}

# --- 2. start the proxy --------------------------------------------------------
if ($NoStart) {
  Write-Say "skipping proxy start (-NoStart). Start later with: .\start-desktop-proxy.cmd start"
  $startFailed = $false
} else {
  Write-Say "starting the desktop proxy"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'start-desktop-proxy.ps1') -Action start
  $startFailed = ($LASTEXITCODE -ne 0)
  if ($startFailed) {
    Write-Warn "the proxy did not start - see the log under $StateDir\logs, then:"
    Write-Warn "  .\start-desktop-proxy.cmd start"
  }
}

# --- 3. instructions -----------------------------------------------------------
$Port = 4002
if ($env:CLAUDE_DESKTOP_PORT) { $Port = [int]$env:CLAUDE_DESKTOP_PORT }
if ($env:CLAUDE_DESKTOP_LITELLM_KEY) { $Key = $env:CLAUDE_DESKTOP_LITELLM_KEY }
else { $Key = 'sk-claude-desktop-local' }

Write-Host ""
Write-Say "Point Claude Desktop at the gateway"
Write-Host ""
Write-Host "  In Claude Desktop:"
Write-Host "    1. Help -> Troubleshooting -> Enable Developer Mode"
Write-Host "    2. Claude menu -> Developer -> Configure Third-Party Inference..."
Write-Host "    3. Connection section:"
Write-Host "         Inference provider  : Gateway"
Write-Host "         Gateway base URL    : http://127.0.0.1:$Port"
Write-Host "         Gateway API key     : $Key"
Write-Host "         Gateway auth scheme : bearer"
Write-Host "    4. Apply Changes (older builds: `"Apply locally`"), then restart Claude Desktop."
Write-Host ""
Write-Host "  Model that will appear in the picker:  claude-opus-5-5"
Write-Host ""
Write-Host "  Verify from the shell:  .\verify.cmd"
Write-Host ""
Write-Host "  Heads-up: enabling third-party inference replaces the subscription"
Write-Host "  account path for the desktop app. Flip the provider back to default"
Write-Host "  to return to your Claude account."
Write-Host ""

if ($startFailed) { exit 1 }
exit 0
