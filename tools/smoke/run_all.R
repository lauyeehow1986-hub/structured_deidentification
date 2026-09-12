# tools/smoke/run_all.R — run every headless smoke suite in a fresh R process
# and aggregate the result. Run from the repo root:
#   & "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" tools/smoke/run_all.R
if (!file.exists("app/global.R")) stop("Run from the repo root (where app/ lives).")
rscript <- file.path(R.home("bin"),
                     if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
scripts <- c("smoke1_core.R", "smoke2_sdc_docs.R", "smoke3_pipeline.R", "smoke4_pf.R")
fails <- 0L
for (s in scripts) {
  cat("\n##########  ", s, "  ##########\n", sep = "")
  rc <- system2(rscript, shQuote(file.path("tools", "smoke", s)))
  if (rc != 0L) fails <- fails + 1L
}
cat(sprintf("\n##########  SMOKE TOTAL: %d/%d suites passed  ##########\n",
            length(scripts) - fails, length(scripts)))
quit(status = if (fails) 1L else 0L)
