# tools/verify_clean_machine.ps1 — run ON the target after extracting the zip
# (from inside the extracted folder). Verifies the bundle is self-contained and
# usable: worst-case path budget against the ACTUAL install root, every critical
# R package loads from the bundle alone, and a smoke de-id produces output with a
# verified tamper-evident audit chain. Emits PASS/FAIL.
param([string]$Bundle = ".")
$ErrorActionPreference = "Stop"
$bundleAbs = (Resolve-Path -LiteralPath $Bundle).Path
Set-Location $bundleAbs
$fail = 0

Write-Host "== 1. MAX_PATH audit against the actual install root =="
& powershell -NoProfile -File (Join-Path $bundleAbs "tools\audit_pathlen.ps1") -Path $bundleAbs -Root $bundleAbs -Top 5
if ($LASTEXITCODE -ne 0) { $fail++ }

Write-Host "`n== 2. Bundled R loads packages + smoke de-id =="
$rs = Join-Path $bundleAbs "bin\R\bin\Rscript.exe"
if (!(Test-Path $rs)) {
  $rs = (Get-ChildItem (Join-Path $bundleAbs "bin\R") -Recurse -Filter Rscript.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (-not $rs) { Write-Host "FAIL: no Rscript in bundle." -ForegroundColor Red; Write-Host "`nVERIFY FAIL"; exit 1 }

$smoke = Join-Path $env:TEMP "sds_verify_smoke.R"
$lines = @(
  'suppressWarnings(suppressMessages(source("app/global.R", local=FALSE)))',
  'need <- c("shiny","DT","openssl","sodium","data.table","xml2","pdftools","tesseract","magick","sdcMicro","future.apply","mirai","jsonlite")',
  'miss <- need[!vapply(need, requireNamespace, logical(1), quietly=TRUE)]',
  'if (length(miss)) stop("MISSING from bundle: ", paste(miss, collapse=", "))',
  'tmp <- file.path(tempdir(),"sds_v"); unlink(tmp, recursive=TRUE)',
  'proj <- se_project_create(tmp,"verify",actor="v",hash_scope="project")',
  'proj$policy$columns <- list(nric=list(identifier="nric",action="pseudonymize")); se_project_save(proj)',
  'd <- file.path(tmp,"in"); dir.create(d)',
  'write.csv(data.frame(nric=c("S1234567D","S7654321J")), file.path(d,"s.csv"), row.names=FALSE)',
  'res <- se_batch_run(proj, se_batch_plan(d), opts=list(actor="v"))',
  'p <- se_project_paths(tmp)',
  'stopifnot(res$totals$ok==1L, file.exists(file.path(p$outputs,"s.deid.csv")), isTRUE(se_audit_verify(p$audit)$ok))',
  'cat("SMOKE OK\n")'
)
Set-Content -Path $smoke -Value $lines -Encoding ascii   # no BOM: Rscript rejects a UTF-8 BOM

# neutralize any per-user R library so this proves the BUNDLE is self-contained
$env:R_LIBS_USER = "C:\__sds_no_user_lib__"
$env:R_LIBS_SITE = ""
& $rs $smoke
if ($LASTEXITCODE -ne 0) { $fail++; Write-Host "FAIL: smoke de-id failed." -ForegroundColor Red }
Remove-Item Env:\R_LIBS_USER -ErrorAction SilentlyContinue
Remove-Item Env:\R_LIBS_SITE -ErrorAction SilentlyContinue
Remove-Item $smoke -ErrorAction SilentlyContinue

if ($fail) { Write-Host "`nVERIFY FAIL ($fail issue(s))" -ForegroundColor Red; exit 1 }
Write-Host "`nVERIFY PASS - bundle is MAX_PATH-safe and self-contained." -ForegroundColor Green; exit 0
