@echo off
REM run_batch.bat - pure-cmd headless batch launcher. No PowerShell required.
REM All arguments pass straight through to app\batch_cli.R.
REM   run_batch.bat --project <dir> --inputs <folder|glob|;-list> [--recursive]
REM                 [--workers N] [--out-format csv|xlsx] [--actor NAME]
REM                 [--force] [--strict] [--no-pf]
setlocal
cd /d "%~dp0"

set "RSCRIPT="
if exist "%~dp0bin\R\bin\Rscript.exe" set "RSCRIPT=%~dp0bin\R\bin\Rscript.exe"
if not defined RSCRIPT for /r "%~dp0bin\R" %%R in (Rscript.exe) do if not defined RSCRIPT set "RSCRIPT=%%R"
if not defined RSCRIPT for /f "delims=" %%D in ('dir /b /ad /o-n "C:\Program Files\R\R-*" 2^>nul') do if not defined RSCRIPT if exist "C:\Program Files\R\%%D\bin\Rscript.exe" set "RSCRIPT=C:\Program Files\R\%%D\bin\Rscript.exe"
if not defined RSCRIPT (
  echo No R found. Bundle R under bin\R or install R 4.5+.
  exit /b 1
)

if exist "%~dp0bin\python\python.exe" set "SE_PYTHON=%~dp0bin\python\python.exe"

"%RSCRIPT%" "app\batch_cli.R" %*
exit /b %ERRORLEVEL%
