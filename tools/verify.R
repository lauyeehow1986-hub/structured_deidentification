# tools/verify.R - pure-R clean-machine verifier (no PowerShell).
# Run from the extracted bundle root via tools\verify.bat, which first neutralizes
# any per-user / site R library so this proves the BUNDLE alone is self-contained.
# Checks: (1) worst-case MAX_PATH budget against the ACTUAL install root,
# (2) every critical package loads from the bundle alone, (3) a smoke de-id runs
# and its tamper-evident audit chain verifies. Prints VERIFY PASS / VERIFY FAIL
# and sets the process exit status.

fail <- 0L

## 1. MAX_PATH audit against the actual install root -------------------------
cat("== 1. MAX_PATH audit against the actual install root ==\n")
root    <- normalizePath(getwd(), winslash = "\\", mustWork = TRUE)
rootlen <- nchar(sub("[\\\\/]+$", "", root)) + 1L   # +1 for the separator before rel
files   <- list.files(".", recursive = TRUE, all.files = TRUE,
                       no.. = TRUE, include.dirs = FALSE)
warn_at <- 240L; max_at <- 255L
if (!length(files)) {
  cat("No files under", root, "\n")
} else {
  abs <- rootlen + nchar(files)
  o   <- order(abs, decreasing = TRUE)
  cat(sprintf("Assumed root: %s  (len %d)\n", root, rootlen))
  cat(sprintf("Files: %d   Longest absolute: %d   Budget: warn>%d fail>%d\n",
              length(files), max(abs), warn_at, max_at))
  cat("\nTop 5 longest (worst-case absolute):\n")
  for (i in head(o, 5L)) cat(sprintf("%4d  %s\n", abs[i], files[i]))
  nover <- sum(abs > max_at)
  nwarn <- sum(abs > warn_at & abs <= max_at)
  if (nwarn) cat(sprintf("\nWARN: %d file(s) between %d and %d.\n", nwarn, warn_at, max_at))
  if (nover) { cat(sprintf("\nFAIL: %d file(s) exceed %d.\n", nover, max_at)); fail <- fail + 1L }
  else cat("\nPASS: all paths within budget.\n")
}

## 2. Bundled R loads packages + smoke de-id --------------------------------
cat("\n== 2. Bundled R loads packages + smoke de-id ==\n")
ok <- tryCatch({
  suppressWarnings(suppressMessages(source("app/global.R", local = FALSE)))
  need <- c("shiny","DT","openssl","sodium","data.table","xml2","pdftools",
            "tesseract","magick","sdcMicro","future.apply","mirai","jsonlite")
  miss <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
  if (length(miss)) stop("MISSING from bundle: ", paste(miss, collapse = ", "))
  tmp <- file.path(tempdir(), "sds_v"); unlink(tmp, recursive = TRUE)
  proj <- se_project_create(tmp, "verify", actor = "v", hash_scope = "project")
  proj$policy$columns <- list(nric = list(identifier = "nric", action = "pseudonymize"))
  se_project_save(proj)
  d <- file.path(tmp, "in"); dir.create(d)
  write.csv(data.frame(nric = c("S1234567D", "S7654321J")),
            file.path(d, "s.csv"), row.names = FALSE)
  res <- se_batch_run(proj, se_batch_plan(d), opts = list(actor = "v"))
  p <- se_project_paths(tmp)
  stopifnot(res$totals$ok == 1L,
            file.exists(file.path(p$outputs, "s.deid.csv")),
            isTRUE(se_audit_verify(p$audit)$ok))
  cat("SMOKE OK\n"); TRUE
}, error = function(e) { cat("FAIL:", conditionMessage(e), "\n"); FALSE })
if (!isTRUE(ok)) fail <- fail + 1L

if (fail) { cat(sprintf("\nVERIFY FAIL (%d issue(s))\n", fail)); quit(status = 1L) }
cat("\nVERIFY PASS - bundle is MAX_PATH-safe and self-contained.\n")
quit(status = 0L)
