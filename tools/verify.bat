@echo off
REM tools\verify.bat - pure-cmd clean-machine verifier (no PowerShell).
REM Run it from anywhere; it verifies the bundle this file lives in. It neutralizes
REM any per-user / site R library so the check proves the BUNDLE alone is usable.
setlocal
pushd "%~dp0.."

set "RSCRIPT="
if exist "bin\R\bin\Rscript.exe" set "RSCRIPT=%CD%\bin\R\bin\Rscript.exe"
if not defined RSCRIPT for /r "bin\R" %%R in (Rscript.exe) do if not defined RSCRIPT set "RSCRIPT=%%R"
if not defined RSCRIPT for /f "delims=" %%D in ('dir /b /ad /o-n "C:\Program Files\R\R-*" 2^>nul') do if not defined RSCRIPT if exist "C:\Program Files\R\%%D\bin\Rscript.exe" set "RSCRIPT=C:\Program Files\R\%%D\bin\Rscript.exe"
if not defined RSCRIPT (
  echo FAIL: no Rscript in bundle.
  echo VERIFY FAIL
  popd
  exit /b 1
)

REM Neutralize any per-user / site R library so this proves the BUNDLE alone works.
set "R_LIBS_USER=C:\__sds_no_user_lib__"
set "R_LIBS_SITE="

"%RSCRIPT%" "tools\verify.R"
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
