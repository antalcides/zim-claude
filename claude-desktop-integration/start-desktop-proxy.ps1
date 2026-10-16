<#
.SYNOPSIS
  Dedicated LiteLLM proxy (:4002) for Claude Desktop.

.DESCRIPTION
  Windows port of start-desktop-proxy.sh, which lives beside this file:

    Claude Desktop --> LiteLLM :4002 --> Token Juice (OpenAI) --> DeepSeek

  Runs on its own port so it NEVER disturbs the zim-claude CLI proxy on :4000.

  The PID and log files are shared with windows\start-proxies.ps1 (the manager
  windows\win-install.bat installs), under
  %USERPROFILE%\.local\share\zim-claude\{run,logs}. The two managers therefore
  interoperate: start with one, stop or check status with the other. A PID file
  left stale by a reboot or a temp cleaner is detected and replaced.

  No secrets live in this file. The upstream key is read from the env profile
  (default %USERPROFILE%\claude-source\deepseek-claude) and the gateway key
  from CLAUDE_DESKTOP_LITELLM_KEY.

  Config served is THIS folder's litellm-config.desktop.yaml, exactly as the
  bash original serves the copy beside it. If you installed with
  windows\win-install.bat and hand-edit the installed copy instead, point
  CLAUDE_DESKTOP_CONFIG at it (see the README).

.PARAMETER Action
  start | stop | restart | status | logs | gateway | help   (default: start)

.EXAMPLE
  .\start-desktop-proxy.cmd start
  .\start-desktop-proxy.cmd status
  .\start-desktop-proxy.cmd gateway
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'gateway', 'help')]
  [string]$Action = 'start'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# --- paths -------------------------------------------------------------------
# Scripts here run in place (nothing is copied to .local\bin), so the config is
# the file in this folder - the same default the bash original uses.
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path

# /tmp does not exist on Windows. The log and PID file land in the same state
# directory windows\start-proxies.ps1 uses, with the same file names, so both
# managers track the same process.
$StateDir = Join-Path $env:USERPROFILE '.local\share\zim-claude'
$LogDir   = Join-Path $StateDir 'logs'
$RunDir   = Join-Path $StateDir 'run'

if ($env:CLAUDE_DESKTOP_PORT)       { $Port = [int]$env:CLAUDE_DESKTOP_PORT }       else { $Port = 4002 }
if ($env:CLAUDE_DESKTOP_CONFIG)     { $Config = $env:CLAUDE_DESKTOP_CONFIG }         else { $Config = Join-Path $Dir 'litellm-config.desktop.yaml' }
if ($env:CLAUDE_DESKTOP_LOG)        { $Log = $env:CLAUDE_DESKTOP_LOG }               else { $Log = Join-Path $LogDir 'desktop.log' }
if ($env:CLAUDE_DESKTOP_PID_FILE)   { $PidFile = $env:CLAUDE_DESKTOP_PID_FILE }      else { $PidFile = Join-Path $RunDir 'desktop.pid' }

if ($env:LITELLM_ENV_FILE) { $EnvFile = $env:LITELLM_ENV_FILE }
else { $EnvFile = Join-Path $env:USERPROFILE 'claude-source\deepseek-claude' }

if ($env:CLAUDE_DESKTOP_LITELLM_KEY) { $GatewayKey = $env:CLAUDE_DESKTOP_LITELLM_KEY }
else { $GatewayKey = 'sk-claude-desktop-local' }

# --- output ------------------------------------------------------------------
# Diagnostics go to stderr so stdout stays clean for anything that pipes the
# output; 'gateway' is the one action that writes to stdout, because its whole
# purpose is to be pasted into Claude Desktop.
function Write-Log { param([string]$m) [Console]::Error.WriteLine("[desktop-proxy] $m") }
function Write-Err { param([string]$m) [Console]::Error.WriteLine("[desktop-proxy] $m") }
function Write-Ok  { param([string]$m) [Console]::Error.WriteLine("[desktop-proxy] $m") }

# --- litellm -----------------------------------------------------------------
# Same order as windows\start-proxies.ps1: an explicit override, then PATH,
# then the per-user Scripts directory pip install --user uses, then .local\bin,
# then a virtualenv built at the Linux layout, then a last sweep of %APPDATA%
# \Python. Both desktop managers therefore share one litellm.
function Get-LiteLLMBin {
  if ($env:LITELLM_BIN) { return $env:LITELLM_BIN }
  $cmd = Get-Command litellm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    (Join-Path $env:APPDATA 'Python\Scripts\litellm.exe'),
    (Join-Path $env:USERPROFILE '.local\bin\litellm.exe'),
    (Join-Path $StateDir 'venv\Scripts\litellm.exe')
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  $pyRoot = Join-Path $env:APPDATA 'Python'
  if (Test-Path -LiteralPath $pyRoot) {
    $found = Get-ChildItem -Path $pyRoot -Filter 'litellm.exe' -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  return $null
}

# --- health / process state --------------------------------------------------

function Test-PortAnswers {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health/liveliness" `
                           -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Get-TrackedPid {
  if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
  $raw = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $raw) { return $null }
  $value = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$value)) { return $null }
  return $value
}

function Test-Running {
  $p = Get-TrackedPid
  if (-not $p) { return $false }
  return [bool](Get-Process -Id $p -ErrorAction SilentlyContinue)
}

# --- profile / config validation ---------------------------------------------

# The env file uses POSIX `export NAME="value"` syntax, kept identical to the
# Linux profile so one file works on both platforms (and in Git Bash).
function Import-Profile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "env file not found: $Path  (run windows\win-install.bat first)"
  }
  $vars = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?(.*?)"?\s*$') {
      $vars[$Matches[1]] = $Matches[2]
    }
  }
  return $vars
}

# Every os.environ/<VAR> the config references must be set, or litellm starts
# and fails later with an opaque auth error. Checking up front names the
# missing variable while it is still actionable. Mirrors start-desktop-proxy.sh.
function Assert-ConfigEnv {
  param([string]$ConfigPath, $ProfileVars)
  $text = Get-Content -LiteralPath $ConfigPath -Raw
  $missing = @()
  foreach ($m in [regex]::Matches($text, 'os\.environ/([A-Za-z_][A-Za-z0-9_]*)')) {
    $name = $m.Groups[1].Value
    if ($name -eq 'CLAUDE_DESKTOP_LITELLM_KEY') { continue }   # supplied from $GatewayKey
    if (-not $ProfileVars.ContainsKey($name) -or [string]::IsNullOrEmpty($ProfileVars[$name])) {
      $missing += $name
    }
  }
  if ($missing.Count -gt 0) {
    throw ("config $ConfigPath references unset variable(s): " +
           (($missing | Sort-Object -Unique) -join ', '))
  }
}

# Can this account open <path> for writing? The PID and log files live in the
# shared state dir, where a file or folder created by an elevated session (or
# stamped with deny ACEs by a tool) is not writable by a normal shell. Finding
# that out AFTER litellm is up would orphan it, so both are probed before the
# spawn. Sharing is allowed: an already-running proxy holding the log open is
# not this check's business (Test-Running and Test-PortAnswers ran earlier).
function Test-Writable {
  param([string]$Path)
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $fs.Close()
    return $true
  } catch { return $false }
}

# --- orphan cleanup -----------------------------------------------------------
# The bash original pkills "litellm --config <this config>" when the port
# answers with no PID file. The Windows equivalent matches litellm processes by
# command line. Scoped to THIS config path: a CLI proxy or a differently
# configured gateway is never touched.
function Stop-Orphans {
  $procs = Get-CimInstance Win32_Process -Filter "Name LIKE 'litellm%'" -ErrorAction SilentlyContinue
  $killed = 0
  foreach ($p in $procs) {
    if ($p.CommandLine -and ($p.CommandLine -like "*$Config*")) {
      Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
      $killed++
    }
  }
  return $killed
}

# --- actions ------------------------------------------------------------------

function Start-One {
  if (Test-Running) {
    Write-Log "already running (pid $(Get-TrackedPid)) on :$Port."
    return $true
  }
  if (Test-PortAnswers) {
    Write-Err "port :$Port is answering but no PID file exists; run '$PSCommandPath restart'."
    return $false
  }

  $bin = Get-LiteLLMBin
  if (-not $bin) {
    Write-Err "litellm not found. Run windows\win-install.bat, or: python -m pip install --user `"litellm[proxy]`""
    return $false
  }
  if (-not (Test-Path -LiteralPath $Config)) {
    Write-Err "config not found: $Config"; return $false
  }

  $profileVars = @{}
  try { $profileVars = Import-Profile -Path $EnvFile }
  catch { Write-Err $_.Exception.Message; return $false }
  try { Assert-ConfigEnv -ConfigPath $Config -ProfileVars $profileVars }
  catch { Write-Err $_.Exception.Message; return $false }

  # Build the child environment explicitly rather than mutating ours for good:
  # save/restore around Start-Process keeps this process clean and makes
  # repeated starts correct.
  $childEnv = @{}
  foreach ($k in $profileVars.Keys) { $childEnv[$k] = $profileVars[$k] }
  $childEnv['CLAUDE_DESKTOP_LITELLM_KEY'] = $GatewayKey

  New-Item -ItemType Directory -Force -Path $LogDir, $RunDir | Out-Null

  Write-Log "starting proxy on :$Port  (config: $Config)"
  Write-Log "gateway key for Claude Desktop: $GatewayKey"
  Write-Log "log: $Log"

  # Probe the PID and log files before spawning litellm: failing to write
  # them afterwards would leave a running proxy that nothing tracks. The
  # usual cause is an ACL left behind by an elevated session on the state
  # directory; the fix needs the same elevation, so spell it out.
  # The stderr companion lives beside the log, so an overridden
  # CLAUDE_DESKTOP_LOG moves both together. Defaults to desktop.err.log in
  # the same directory windows\start-proxies.ps1 writes.
  $errLog = Join-Path (Split-Path -Parent $Log) 'desktop.err.log'
  foreach ($probe in @(
    @('PID file', $PidFile),
    @('log file', $Log),
    @('error log file', $errLog)
  )) {
    if (-not (Test-Writable -Path $probe[1])) {
      Write-Err "cannot write the $($probe[0]): $($probe[1])"
      Write-Err "  The file or its folder is not writable by this account - usually an"
      Write-Err "  ACL left by an elevated session. In an ADMINISTRATOR PowerShell run:"
      Write-Err "    icacls `"$StateDir`" /reset /t /c /q"
      Write-Err "  then start again."
      return $false
    }
  }

  # Start-Process has no -Environment before PowerShell 7.4, so the child
  # inherits this process's environment. Save/restore keeps that mutation
  # contained.
  $saved = @{}
  foreach ($k in $childEnv.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
    [Environment]::SetEnvironmentVariable($k, $childEnv[$k], 'Process')
  }

  $proc = $null
  try {
    # Start-Process joins -ArgumentList with spaces and never quotes the
    # elements. An unquoted config path containing a space - "C:\Users\Rafael
    # Olivo\..." - reaches litellm as two arguments and dies with "Unknown
    # command: Olivo\...". Quote the path so the child sees one argument.
    $proc = Start-Process -FilePath $bin `
                          -ArgumentList @('--config', ('"{0}"' -f $Config), '--port', "$Port") `
                          -WindowStyle Hidden -PassThru `
                          -RedirectStandardOutput $Log `
                          -RedirectStandardError $errLog
    Set-Content -LiteralPath $PidFile -Value $proc.Id -NoNewline
  } finally {
    foreach ($k in $saved.Keys) {
      [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')
    }
  }

  # Poll for health - litellm takes several seconds to import and bind. 30s
  # matches the bash manager's budget.
  for ($i = 1; $i -le 30; $i++) {
    if (Test-PortAnswers) {
      Write-Ok "up and healthy (pid $($proc.Id)) on :$Port."
      return $true
    }
    Start-Sleep -Seconds 1
  }

  Write-Err "proxy did not become healthy within 30s - last log lines:"
  foreach ($f in @($Log, $errLog)) {
    if (Test-Path -LiteralPath $f) {
      Get-Content -LiteralPath $f -Tail 20 | ForEach-Object { [Console]::Error.WriteLine("    $_") }
    }
  }
  return $false
}

function Stop-One {
  if (Test-Running) {
    $p = Get-TrackedPid
    Write-Log "stopping proxy (pid $p)..."
    Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Log "stopped."
    return
  }

  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  if (Test-PortAnswers) {
    Write-Log "no PID file, but :$Port still answers - killing orphan(s) bound to this config"
    $killed = Stop-Orphans
    Start-Sleep -Seconds 1
    if (Test-PortAnswers) {
      Write-Err ":$Port still answers after killing $killed orphan(s) - stop the process manually."
    } else {
      Write-Log "stopped."
    }
    return
  }
  Write-Log "not tracked as running."
}

function Show-Status {
  if (Test-Running) {
    $p = Get-TrackedPid
    if (Test-PortAnswers) { $state = 'healthy' } else { $state = 'NOT answering' }
    Write-Log "running (pid $p) on :$Port - $state"
  } else {
    Write-Log "not running (:$Port)"
  }
}

function Show-Gateway {
  # Exactly the values to paste into Claude Desktop's Third-Party Inference UI.
  # This is the one action that writes to stdout, because the point is to copy it.
  Write-Output "Gateway base URL : http://127.0.0.1:$Port"
  Write-Output "Gateway API key  : $GatewayKey"
  Write-Output "Auth scheme      : bearer"
}

# --- dispatch -----------------------------------------------------------------

switch ($Action) {
  'start'   { if (-not (Start-One)) { exit 1 } }
  'stop'    { Stop-One }
  'restart' {
    Stop-One
    if (-not (Start-One)) { exit 1 }
  }
  'status'  { Show-Status }
  'logs'    {
    $files = @()
    foreach ($f in @($Log, (Join-Path (Split-Path -Parent $Log) 'desktop.err.log'))) {
      if (Test-Path -LiteralPath $f) { $files += $f }
    }
    if ($files.Count -eq 0) { Write-Err "no log files yet - start the proxy first."; exit 1 }
    Get-Content -LiteralPath $files -Tail 50 -Wait
  }
  'gateway' { Show-Gateway }
  'help'    { Get-Help $PSCommandPath -Detailed }
}
