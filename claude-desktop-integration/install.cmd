@echo off
setlocal
rem install.cmd - install the Claude Desktop gateway on Windows, in place.
rem
rem This is the entry point for the Windows port of install.sh. It is a .cmd
rem rather than a .ps1 for two reasons: it runs even when the machine's
rem execution policy would refuse a bare .ps1, and it is a real executable so
rem double-clicking works.
rem
rem All flags pass straight through to install.ps1:
rem
rem   install.cmd               check prerequisites, start the :4002 proxy
rem   install.cmd -NoStart      everything except starting the proxy
rem   install.cmd -Managed      refused: managed settings are Linux-only
rem   install.cmd -Help
rem
rem Nothing here touches the zim-claude CLI proxy on :4000. For the installer
rem that also sets up the CLI side, see windows\win-install.bat.
rem
rem -ExecutionPolicy Bypass applies to this invocation only; it does not change
rem the machine's policy. -NoProfile keeps a user profile from altering the run.

set "SCRIPT=%~dp0install.ps1"

if not exist "%SCRIPT%" (
  echo [x] cannot find "%SCRIPT%"
  echo     run this from inside the repo's claude-desktop-integration\ directory.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
