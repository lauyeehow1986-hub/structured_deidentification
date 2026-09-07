@echo off
REM run.bat - pure-cmd launcher for the Structured De-identification app.
REM No PowerShell required: locates bundled (or system) R, points reticulate at
REM the bundled Python, opens the browser, and starts Shiny on 127.0.0.1:7788.
setlocal
cd /d "%~dp0"

set "RSCRIPT="
if exist "%~dp0bin\R\bin\Rscript.exe" set "RSCRIPT=%~dp0bin\R\bin\Rscript.exe"
if not defined RSCRIPT for /r "%~dp0bin\R" %%R in (Rscript.exe) do if not defined RSCRIPT set "RSCRIPT=%%R"
if not defined RSCRIPT for /f "delims=" %%D in ('dir /b /ad /o-n "C:\Program Files\R\R-*" 2^>nul') do if not defined RSCRIPT if exist "C:\Program Files\R\%%D\bin\Rscript.exe" set "RSCRIPT=C:\Program Files\R\%%D\bin\Rscript.exe"
if not defined RSCRIPT (
  echo No R found. Bundle R under bin\R or install R 4.5+.
  pause
  exit /b 1
)
echo Using R: %RSCRIPT%

if exist "%~dp0bin\python\python.exe" (
  set "SE_PYTHON=%~dp0bin\python\python.exe"
  echo Bundled Python: %~dp0bin\python\python.exe
)

start "" "http://127.0.0.1:7788"
"%RSCRIPT%" -e "options(shiny.port=7788); shiny::runApp('app', launch.browser=FALSE, host='127.0.0.1')"
pause
