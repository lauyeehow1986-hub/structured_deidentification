# run_batch.ps1 — headless batch launcher. Args pass through to app/batch_cli.R.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Find-Rscript {
  $b = Join-Path $root "bin\R\bin\Rscript.exe"; if (Test-Path $b) { return $b }
  $g = Get-ChildItem (Join-Path $root "bin\R") -Recurse -Filter Rscript.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($g) { return $g.FullName }
  $s = Get-ChildItem "C:\Program Files\R" -Directory -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -like "R-*" } | Sort-Object Name -Descending | Select-Object -First 1
  if ($s) { $rs = Join-Path $s.FullName "bin\Rscript.exe"; if (Test-Path $rs) { return $rs } }
  throw "No R found. Bundle R under bin\R or install R 4.5+."
}
$py = Join-Path $root "bin\python\python.exe"; if (Test-Path $py) { $env:SE_PYTHON = $py }
Set-Location $root
& (Find-Rscript) "app\batch_cli.R" @args
exit $LASTEXITCODE
