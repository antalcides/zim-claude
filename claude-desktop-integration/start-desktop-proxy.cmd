@echo off
rem start-desktop-proxy.cmd - Windows entry point for start-desktop-proxy.ps1.
rem
rem Same reason as the shims in windows\: a .ps1 cannot be run by bare name,
rem and a machine whose execution policy refuses a bare .ps1 - the default on
rem Windows clients, and what happens to anything from a downloaded ZIP -
rem would otherwise block every documented form.
rem
rem All arguments are forwarded verbatim, so `start-desktop-proxy.cmd status`,
rem `start-desktop-proxy.cmd gateway` and the rest of the README's forms work
rem unchanged. -ExecutionPolicy Bypass is scoped to this invocation only; it
rem does not change the machine's policy. -NoProfile keeps a user profile from
rem altering the run.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-desktop-proxy.ps1" %*

rem Propagate the exit code. Without this, cmd would report the exit code of
rem the last command in this file and swallow failures.
exit /b %ERRORLEVEL%
