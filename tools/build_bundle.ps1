# tools/build_bundle.ps1 — assemble the MAX_PATH-safe portable zip.
# Assembles a release tree, prunes runtime-unneeded deep subtrees (so the bundled
# R library stays under the Windows 260-char limit when extracted into Downloads),
# audits worst-case path length, checks dependency closure, then zips.
# Run AFTER tools/stage_r.ps1 has populated bin\R.
param(
  # Build to a SHORT external root by default: assembling the tree inside a deep
  # worktree/clone path can itself approach MAX_PATH mid-build (the extracted
  # bundle is fine — that is what audit_pathlen certifies against $Root).
  [string]$Out  = "C:\sds_build",
  [string]$Name = "sds",
  [switch]$IncludePython = $true,
  [switch]$IncludeLlama  = $false,
  [switch]$IncludeModels = $false,
  [string]$Root = "C:\Users\a_twenty_char_userxx\Downloads\sds"  # conservative audit root
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $repo

function Robo($src, $dst) {
  robocopy $src $dst /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $src -> $dst" }
  $global:LASTEXITCODE = 0
}

$outRoot = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $repo $Out }
$stage = Join-Path $outRoot $Name
if (Test-Path $stage) {
  # Remove-Item -Recurse chokes on near-MAX_PATH trees; mirror-empty first.
  $mt = Join-Path $env:TEMP "__sds_empty_mir__"; New-Item -ItemType Directory -Force -Path $mt | Out-Null
  robocopy $mt $stage /MIR /NFL /NDL /NJH /NJS /NP | Out-Null; $global:LASTEXITCODE = 0
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $mt -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# 1) app code + launchers + docs + samples + tools (audit/verify run on target)
foreach ($d in "app","docs","samples","tools") { if (Test-Path $d) { Robo $d (Join-Path $stage $d) } }
foreach ($f in "run.bat","run.ps1","run_batch.bat","run_batch.ps1","README.md","CLAUDE.md") {
  if (Test-Path $f) { Copy-Item $f $stage }
}
# internal dev docs do not ship
$devdocs = Join-Path $stage "docs\superpowers"
if (Test-Path $devdocs) { Remove-Item $devdocs -Recurse -Force }

# 2) runtimes
if (!(Test-Path "bin\R")) { throw "bin\R not found - run tools\stage_r.ps1 first." }
Robo "bin\R" (Join-Path $stage "bin\R")
if ($IncludePython -and (Test-Path "bin\python")) { Robo "bin\python" (Join-Path $stage "bin\python") }
if ($IncludeLlama  -and (Test-Path "bin\llama"))  { Robo "bin\llama"  (Join-Path $stage "bin\llama") }
if ($IncludeModels -and (Test-Path "models"))     { Robo "models"     (Join-Path $stage "models") }

# 3) prune runtime-unneeded deep subtrees (kills RcppEigen/RcppArmadillo include
#    depth + help/doc/html; shrinks size). Never touches libs/ R/ Meta/ data/.
$prune = @("include","doc","html","help","tests","test","examples","po")
$stageLib = Join-Path $stage "bin\R\library"
if (Test-Path $stageLib) {
  foreach ($pdir in $prune) {
    Get-ChildItem $stageLib -Recurse -Directory -Filter $pdir -ErrorAction SilentlyContinue |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Get-ChildItem $stage -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $stage -Recurse -File -Filter *.pyc -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
# per-project scratch/state must never ship
foreach ($junk in "inputs","outputs","work") {
  Get-ChildItem $stage -Recurse -Directory -Filter $junk -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# 4) audit + closure — fail the build on any violation
& powershell -NoProfile -File (Join-Path $repo "tools\audit_pathlen.ps1") -Path $stage -Root $Root
if ($LASTEXITCODE -ne 0) { throw "MAX_PATH audit FAILED - prune more or shorten the root." }
& powershell -NoProfile -File (Join-Path $repo "tools\check_closure.ps1") -Bundle $stage
if ($LASTEXITCODE -ne 0) { throw "Dependency closure FAILED - stage the missing packages." }

# 5) zip via .NET ZipFile (native, Zip64-capable, no external-exe arg parsing;
#    includeBaseDirectory=$true puts everything under a top-level "<Name>\").
$zip = Join-Path $outRoot ("$Name.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
  $stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
if (!(Test-Path $zip)) { throw "zip step produced no file." }
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ("Built {0} ({1} MB)" -f $zip, $mb) -ForegroundColor Green
