# tools/stage_r.ps1 — materialise a relocatable R under bin\R for the bundle.
# Run on the CONNECTED build laptop. Copies the R runtime (base + recommended
# library), then copies the transitive closure of the app's package dependencies
# (computed by stage_r_deps.R) from wherever they are installed into
# bin\R\library. No compilation: every dependency is already installed here.
param(
  [string]$RHome = "C:\Program Files\R\R-4.5.2",
  [string]$Dest  = "bin\R"
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $repo

function Robo($src, $dst) {
  robocopy $src $dst /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $src -> $dst" }
  $global:LASTEXITCODE = 0
}

# 1) runtime (includes base + recommended library)
$destAbs = Join-Path $repo $Dest
if (Test-Path $destAbs) { Remove-Item $destAbs -Recurse -Force }
Write-Host "Copying R runtime from $RHome ..."
Robo $RHome $destAbs

$rs = Join-Path $destAbs "bin\Rscript.exe"
if (!(Test-Path $rs)) { throw "Rscript not found at $rs after copy." }

# 2) transitive closure of app deps (use the SYSTEM Rscript so the user library
#    is on the search path when resolving installed locations)
$sysRs = Join-Path $RHome "bin\Rscript.exe"
Write-Host "Computing dependency closure ..."
$list = & $sysRs "tools\stage_r_deps.R"
if ($LASTEXITCODE -ne 0) { throw "stage_r_deps.R failed." }

$destLib = Join-Path $destAbs "library"
$copied = 0
foreach ($src in $list) {
  $src = $src.Trim(); if (-not $src) { continue }
  $name = Split-Path $src -Leaf
  $tgt  = Join-Path $destLib $name
  if (Test-Path $tgt) { continue }        # already shipped in the runtime library
  Robo $src $tgt
  $copied++
}
Write-Host ("Staged R into {0}: runtime + {1} closure package(s)." -f $Dest, $copied) -ForegroundColor Green
Write-Host ("Total packages in library: {0}" -f (Get-ChildItem $destLib -Directory).Count)
