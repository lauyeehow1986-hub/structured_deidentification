# run.ps1 — portable launcher for the Structured De-identification app.
# Prefers a bundled R under bin\R (shipped in the air-gapped zip); falls back to
# a system R install. Starts Shiny on a local port and opens the browser.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 7788

function Find-Rscript {
    # 1) bundled portable R
    $bundled = Join-Path $root "bin\R\bin\Rscript.exe"
    if (Test-Path $bundled) { return $bundled }
    # 2) any bin\R\R-*\bin\Rscript.exe
    $glob = Get-ChildItem (Join-Path $root "bin\R") -Recurse -Filter Rscript.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($glob) { return $glob.FullName }
    # 3) system installs
    $sys = Get-ChildItem "C:\Program Files\R" -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "R-*" } | Sort-Object Name -Descending | Select-Object -First 1
    if ($sys) {
        $rs = Join-Path $sys.FullName "bin\Rscript.exe"
        if (Test-Path $rs) { return $rs }
    }
    throw "No R found. Bundle R under bin\R or install R 4.5+."
}

$rscript = Find-Rscript
Write-Host "Using R: $rscript"

# Point reticulate at a bundled Python if present (never auto-provision).
$py = Join-Path $root "bin\python\python.exe"
if (Test-Path $py) { $env:SE_PYTHON = $py; Write-Host "Bundled Python: $py" }

Start-Process "http://127.0.0.1:$port"

& $rscript -e "options(shiny.port=$port); shiny::runApp('app', launch.browser=FALSE, host='127.0.0.1')"
