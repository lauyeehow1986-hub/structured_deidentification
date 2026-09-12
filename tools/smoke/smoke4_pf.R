# Run from the repo root:  Rscript tools/smoke/smoke4_pf.R
# Exercises the default free-text detector (Privacy Filter, ONNX, out-of-process).
# The PF model is NOT in the repo (it ships in the bundle). This script auto-
# discovers it and SKIPS cleanly (exit 0) if it is not present, so it is safe in CI.
if (!file.exists("app/global.R")) stop("Run from the repo root (where app/ lives).")
suppressWarnings(suppressMessages(source("app/global.R")))

# Locate the PF model: SE_PF_DIR, else a built bundle model, else <repo>/models/pf.
pf_dir <- Sys.getenv("SE_PF_DIR", unset = "")
if (!nzchar(pf_dir))
  for (cand in c("C:/sds_build/pfmodel", "C:/sds_build/sds_pf/models/pf",
                 file.path(getwd(), "models", "pf")))
    if (dir.exists(cand)) { pf_dir <- cand; break }
if (nzchar(pf_dir)) Sys.setenv(SE_PF_DIR = pf_dir)
if (!isTRUE(se_pf_config()$available)) {
  cat("SKIP: Privacy Filter model not found (set SE_PF_DIR to a models/pf dir to run).\n")
  cat("      Looked at SE_PF_DIR, C:/sds_build/pfmodel, C:/sds_build/sds_pf/models/pf, ./models/pf\n")
  cat("\n==== SMOKE 4 (Privacy Filter default detector): SKIPPED (model absent) ====\n")
  quit(status = 0)
}

.pass <- 0L; .fail <- 0L; .rows <- c()
T <- function(name, expr) {
  ok <- FALSE; msg <- ""
  tryCatch({ v <- force(expr); ok <- isTRUE(v)
             if (!ok) msg <- paste("->", paste(utils::head(as.character(v),1), collapse=" ")) },
           error = function(e) msg <<- conditionMessage(e))
  if (ok) .pass <<- .pass + 1L else .fail <<- .fail + 1L
  .rows[[length(.rows)+1L]] <<- sprintf("  [%s] %s%s", if (ok) "PASS" else "FAIL", name,
                                        if (ok) "" else paste0("   -- ", msg))
}

cfg <- se_pf_config()
T("PF model discovered (onnx+tokenizer+config present)", isTRUE(cfg$available))
cat("PF dir:", cfg$dir, "\n")

t0 <- Sys.time()
res <- se_pf_scan(c("Patient John Smith was seen by Dr Tan at National Heart Centre Singapore on 3 June.",
                    "Contact next of kin Mary Lim at her home in Bishan."))
cat("PF scan wall time:", round(as.numeric(difftime(Sys.time(), t0, units="secs")),1), "s\n")
T("PF scan returns findings data.frame", is.data.frame(res))
T("PF scan detects PII spans (names/locations)", nrow(res) > 0)
if (nrow(res)) {
  print(utils::head(res[, intersect(c("row","start","end","match","type","identifier","confidence"), names(res))], 12))
  T("PF spans carry text + type", all(c("match","type") %in% names(res)) && any(nzchar(res$match)))
}

# End-to-end: redact_freetext with use_pf=TRUE routes through the PF detector.
df <- data.frame(note = c("Seen by Dr John Smith in Bishan.", "Stable, no complaints."),
                 stringsAsFactors = FALSE)
pol <- se_empty_policy()
pol$columns <- list(note = list(action = "redact_freetext"))
pol$freetext_opts <- list(min_conf = 0.3, use_pf = TRUE)
out <- se_deidentify_table(df, pol, key = se_derive_key("k","s"))$data
cat("PF-redacted note[1]:", out$note[1], "\n")
T("redact_freetext(use_pf=TRUE) alters PII-bearing note", out$note[1] != df$note[1])
T("redact_freetext(use_pf=TRUE) leaves clean note intact", out$note[2] == df$note[2])

cat(paste(.rows, collapse="\n"), "\n")
cat(sprintf("\n==== SMOKE 4 (Privacy Filter default detector): %d PASS / %d FAIL ====\n", .pass, .fail))
if (.fail > 0) quit(status=1)
