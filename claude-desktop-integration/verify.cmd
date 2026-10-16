@echo off
rem verify.cmd - Windows entry point for verify.ps1.
rem
rem Same reason as the shims in windows\: verify.ps1 cannot be run by bare
rem name, and a machine whose execution policy refuses a bare .ps1 - the
rem default on Windows clients, and what happens to anything from a downloaded
rem ZIP - would otherwise block the one command that proves the gateway works.
rem
rem All arguments are forwarded verbatim, so `verify.cmd claude-opus-5-5` works.
rem -ExecutionPolicy Bypass is scoped to this invocation only; it does not
rem change the machine's policy. -NoProfile keeps a user profile from altering
rem the run.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify.ps1" %*

rem Propagate the exit code, so a failed check is visible to callers and scripts.
exit /b %ERRORLEVEL%
