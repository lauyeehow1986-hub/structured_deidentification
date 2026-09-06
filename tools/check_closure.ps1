# tools/check_closure.ps1 — verify the bundle's dependency closure is complete.
# A locked-down, air-gapped target resolves NOTHING at runtime, so every declared
# dependency must already be present in the bundle (the AndyFishing lesson).
#   R:      every package DESCRIPTION Depends/Imports/LinkingTo present in bin\R\library.
#   Python: every dist-info METADATA *unconditional* Requires-Dist present in
#           site-packages. Deps carrying an environment marker (';' ...) or an
#           'extra' are optional/conditional and are only reported, not failed.
param([string]$Bundle = ".")
$ErrorActionPreference = "Stop"
$script:fail = 0

function Normalize-Py([string]$n) { ($n -replace "[-_.]+","-").ToLower() }

# ---- R ----------------------------------------------------------------------
$rlib = Join-Path $Bundle "bin\R\library"
if (Test-Path $rlib) {
  $have = (Get-ChildItem $rlib -Directory).Name
  $rbase = @("base","compiler","datasets","graphics","grDevices","grid","methods",
             "parallel","splines","stats","stats4","tcltk","tools","utils","translations","R")
  foreach ($pkg in Get-ChildItem $rlib -Directory) {
    $desc = Join-Path $pkg.FullName "DESCRIPTION"; if (!(Test-Path $desc)) { continue }
    $txt = Get-Content $desc -Raw
    foreach ($field in "Depends","Imports","LinkingTo") {
      if ($txt -match "(?ms)^$field\s*:\s*(.+?)(?=^\S|\z)") {
        ($matches[1] -split ",") | ForEach-Object {
          $dep = ($_ -replace "\(.*?\)","").Trim() -replace "\s.*",""
          if ($dep -and $dep -notin $rbase -and $dep -notin $have) {
            Write-Host ("R  MISSING: {0} needs {1}" -f $pkg.Name, $dep) -ForegroundColor Red
            $script:fail++
          }
        }
      }
    }
  }
  Write-Host ("R: checked {0} package(s)." -f $have.Count)
} else { Write-Host "No bin\R\library (R not staged yet) - skipping R closure." -ForegroundColor Yellow }

# ---- Python -----------------------------------------------------------------
$site = Join-Path $Bundle "bin\python\Lib\site-packages"
if (Test-Path $site) {
  $have = @(Get-ChildItem $site -Directory -Filter *.dist-info | ForEach-Object {
             Normalize-Py ($_.Name -replace "-\d.*$","") })
  foreach ($di in Get-ChildItem $site -Directory -Filter *.dist-info) {
    $md = Join-Path $di.FullName "METADATA"; if (!(Test-Path $md)) { continue }
    Get-Content $md | Where-Object { $_ -like "Requires-Dist:*" } | ForEach-Object {
      $req = $_ -replace "^Requires-Dist:\s*",""
      if ($req -match ";") { return }                      # conditional / extra -> optional
      $dep = Normalize-Py (($req -split "[ <>=;\(\[!~]")[0])
      if ($dep -and $dep -notin $have) {
        Write-Host ("PY MISSING: {0} -> {1}" -f $di.Name, $dep) -ForegroundColor Red
        $script:fail++
      }
    }
  }
  Write-Host ("Python: checked {0} dist-info package(s)." -f $have.Count)
} else { Write-Host "No bin\python site-packages - skipping Python closure." -ForegroundColor Yellow }

if ($script:fail) { Write-Host ("`nFAIL: {0} missing dependency(ies)." -f $script:fail) -ForegroundColor Red; exit 1 }
Write-Host "`nPASS: dependency closure satisfied." -ForegroundColor Green; exit 0
