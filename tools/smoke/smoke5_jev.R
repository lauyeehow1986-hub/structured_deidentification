# Run from the repo root:  Rscript tools/smoke/smoke5_jev.R
# Exercises the optional slm:jev free-text detector (a separate slm_jev checkout
# plus a local GGUF judge). Part A (the R side: type mapping, fail-closed
# threshold bypass, error reporting) always runs on canned engine output.
# Part B scans live and SKIPS (still exit 0) when slm_jev or its model is absent:
# set SLMJEV_ROOT, SLMJEV_LLAMA_SERVER, SLMJEV_JUDGE_MODEL, SLMJEV_CALIBRATION.
if (!file.exists("app/global.R")) stop("Run from the repo root (where app/ lives).")
suppressWarnings(suppressMessages(source("app/global.R")))

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

# ---- A. R side on canned engine output (synthetic) --------------------------
note <- "Pt Tan Ah Kow, NRIC S1234567D, known HIV. Ward 5."
canned <- '[
 {"row":1,"start":4,"end":13,"match":"Tan Ah Kow","type":"name","identifier":"name",
  "detector":"slm:jev","confidence":0.99,"needs_review":false,"reasons":[]},
 {"row":1,"start":21,"end":29,"match":"S1234567D","type":"nric","identifier":"national_id",
  "detector":"slm:jev","confidence":1.0,"needs_review":false,"reasons":["nric_checksum"]},
 {"row":1,"start":38,"end":40,"match":"HIV","type":null,"identifier":"hiv_sti",
  "detector":"slm:jev","confidence":0.41,"needs_review":true,"reasons":[]},
 {"row":1,"start":43,"end":48,"match":"Ward 5","type":null,"identifier":null,
  "detector":"slm:jev","confidence":null,"needs_review":true,"reasons":["judge_error"]}]'
jf <- se_jev_frame(jsonlite::fromJSON(canned, simplifyDataFrame = TRUE))
T("canned spans parse to 4 findings", nrow(jf) == 4L)
T("types map to the free-text vocabulary",
  identical(jf$type, c("name", "nric", "sensitive", "other")))
T("a judge failure keeps the span (confidence 0, needs_review)",
  jf$confidence[4] == 0 && jf$needs_review[4] && jf$identifier[4] == "other_id")
T("every mapped type is selectable in the UI", all(jf$type %in% .se_ft_types))
T("empty engine output -> empty frame", nrow(se_jev_frame(list())) == 0L)

d <- se_dedup_findings(data.frame(
  row = 1L, column = "note", start = 38L, end = 40L, match = "HIV", type = "sensitive",
  identifier = "hiv_sti", confidence = c(0.9, 0.2), detector = c("pf", "slm:jev"),
  needs_review = c(FALSE, TRUE), stringsAsFactors = FALSE))
T("dedup keeps the needs_review flag of a duplicate", nrow(d) == 1L && d$needs_review)

# redact_freetext: unsure slm:jev spans bypass the confidence floor
fake <- function(texts, kind = "text", column = NULL, strict = FALSE, candidates = NULL) {
  r <- jf; r$row <- 1L; r[r$row <= length(texts), , drop = FALSE]
}
real_scan <- se_jev_scan
assign("se_jev_scan", fake, envir = globalenv())
df <- data.frame(note = note, stringsAsFactors = FALSE)
pol <- se_empty_policy()
pol$columns <- list(note = list(action = "redact_freetext"))
pol$freetext_opts <- list(min_conf = 0.9, use_pf = FALSE, use_jev = TRUE)
out <- se_deidentify_table(df, pol, key = se_derive_key("k", "s"))$data$note
cat("jev-redacted (canned):", out, "\n")
T("confident spans redacted", !grepl("Tan Ah Kow|S1234567D", out))
T("unsure spans below min_conf still redacted (fail closed)", !grepl("HIV|Ward 5", out))
pol$freetext_opts$rejects <- paste("note", "sensitive", "hiv", sep = "\t")
out2 <- se_deidentify_table(df, pol, key = se_derive_key("k", "s"))$data$note
T("a reviewer reject releases an unsure span", grepl("HIV", out2) && !grepl("Ward 5", out2))

# a failed scan: warning + attr in detection; hard stop at export
assign("se_jev_scan", function(texts, kind = "text", column = NULL, strict = FALSE,
                               candidates = NULL) {
  if (strict) stop("slm:jev: boom", call. = FALSE)
  structure(se_jev_frame(list()), error = "boom")
}, envir = globalenv())
ff <- se_detect_freetext(df, "note", use_pf = FALSE, use_jev = TRUE)
T("detection reports a failed scan in attr(jev_error)", identical(attr(ff, "jev_error"), "boom"))
T("export stops when slm:jev fails (never exports un-scanned)",
  inherits(tryCatch(se_deidentify_table(df, pol, key = se_derive_key("k", "s")),
                    error = function(e) e), "error"))
assign("se_jev_scan", real_scan, envir = globalenv())

# engine spans go to the judge as candidates: all Privacy Filter spans plus
# Presidio person spans, one list per text (slm_jev decision 0009)
eng <- function(row, start, end, type, detector)
  data.frame(row = row, start = start, end = end, match = "x", type = type,
             identifier = "name", detector = detector, confidence = 0.85,
             stringsAsFactors = FALSE)
cand <- se_jev_candidates(3L, pf = eng(c(1L, 3L), c(4L, 1L), c(13L, 5L), "name", "pf"),
                          ner = eng(c(1L, 1L), c(4L, 43L), c(13L, 48L),
                                    c("person", "organization"), "ner:presidio"))
T("candidates: one entry per text", length(cand) == 3L)
T("candidates: PF spans and Presidio persons only",
  nrow(cand[[1]]) == 2L && !any(cand[[1]]$start == 43L) && nrow(cand[[2]]) == 0L &&
  nrow(cand[[3]]) == 1L)
cj <- as.character(jsonlite::toJSON(cand, auto_unbox = TRUE))
T("candidates: JSON is an array of span arrays",
  startsWith(cj, '[[{"start":4,"end":13,"type":"name","detector":"pf"}') &&
  grepl(",[],", cj, fixed = TRUE))
T("no engine spans -> no candidates", is.null(se_jev_candidates(2L, NULL, NULL)))
seen <- NULL
assign("se_jev_scan", function(texts, kind = "text", column = NULL, strict = FALSE,
                               candidates = NULL) { seen <<- candidates; se_jev_frame(list()) },
       envir = globalenv())
real_pf <- se_pf_scan
assign("se_pf_scan", function(texts) eng(1L, 4L, 13L, "name", "pf"), envir = globalenv())
invisible(se_detect_freetext(df, "note", use_pf = FALSE, use_jev = TRUE))
T("detection passes PF spans to slm:jev even when PF is not shown",
  length(seen) == 1L && identical(seen[[1]]$start, 4L))
seen <- NULL
invisible(se_deidentify_table(df, pol, key = se_derive_key("k", "s")))
T("export passes the same candidates", length(seen) == 1L && identical(seen[[1]]$end, 13L))
assign("se_pf_scan", real_pf, envir = globalenv())
assign("se_jev_scan", real_scan, envir = globalenv())

old_root <- Sys.getenv("SLMJEV_ROOT"); old_opt <- options(se.slmjev_root = tempfile())
miss <- tryCatch(se_jev_scan("x", strict = TRUE), error = function(e) conditionMessage(e))
options(old_opt)
T("strict scan with slm_jev missing is an error, not an empty result",
  is.character(miss) && grepl("slm:jev", miss))

# ---- B. live scan (optional) -------------------------------------------------
cfg <- se_jev_config()
if (is.null(se_py_binary()) || !isTRUE(cfg$available)) {
  cat("SKIP live scan: bundled Python", if (is.null(se_py_binary())) "absent" else "ok",
      "| missing:", paste(cfg$missing, collapse = ", "), "\n")
} else {
  t0 <- Sys.time()
  live <- se_jev_scan(c(note, "Stable, no complaints.", NA), strict = TRUE)
  cat("slm:jev live scan:", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1),
      "s\n")
  print(live[, c("row", "start", "end", "match", "type", "confidence", "needs_review")])
  T("live: NRIC found by the rules fast path", any(live$match == "S1234567D" & live$type == "nric"))
  T("live: name flagged", any(grepl("Tan Ah Kow", live$match)))
  T("live: detector is slm:jev", all(live$detector == "slm:jev"))
  T("live: offsets index the text",
    all(substring(note, live$start[live$row == 1], live$end[live$row == 1]) ==
        live$match[live$row == 1]))
}

cat(paste(.rows, collapse = "\n"), "\n")
cat(sprintf("\n==== SMOKE 5 (slm:jev detector): %d PASS / %d FAIL ====\n", .pass, .fail))
if (.fail > 0) quit(status = 1)
