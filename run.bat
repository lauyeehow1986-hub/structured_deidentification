@echo off
REM run.bat — double-click launcher for the Structured De-identification app.
REM Delegates to run.ps1 (which locates bundled or system R) with no install.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
pause
