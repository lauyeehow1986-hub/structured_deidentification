# engine_py.R — bridge to the OPTIONAL Python detection engine (Presidio + spaCy
# NER, and optional Ollama LLM). The R rule/validator engine (detect_r.R) always
# works with ZERO Python; this layer adds free-text NER when the bundled Python
# environment is present.
#
# The bundled interpreter is driven OUT-OF-PROCESS (a subprocess of
# bin/python/python.exe running app/python/run_engine.py, JSON in/out), not
# embedded in R. That is deliberate:
#   * On Windows, R's OpenSSL and a standalone Python's OpenSSL cannot safely
#     share one process — embedding Presidio via reticulate crashes with
#     "no OPENSSL_Applink". A subprocess keeps the native libraries apart.
#   * It makes the air-gap boundary trivial: the app never initialises Python
#     in-process and never lets reticulate auto-provision anything from PyPI.
# Everything degrades gracefully: if Python or the model isn't there, we report
# "unavailable" and carry on with rules only.

.se_py_state <- new.env(parent = emptyenv())

#' Path to a bundled/configured Python interpreter, or NULL. Checked by file
#' existence ONLY — never runs anything and never touches the network.
se_py_binary <- function() {
  cand <- c(getOption("se.python", ""),
            Sys.getenv("SE_PYTHON", ""),
            file.path(se_bundle_root(), "bin", "python", "python.exe"),
            file.path(se_bundle_root(), "bin", "python", "bin", "python3"))
  cand <- cand[nzchar(cand)]
  hit <- cand[file.exists(cand)]
  if (length(hit)) hit[1] else NULL
}

#' Run the bundled engine out-of-process. `mode` is "probe" | "ner" | "llm";
#' `payload` is an R list marshalled to JSON on stdin. Returns the parsed JSON
#' response, or NULL on any failure. Never throws.
.se_py_run <- function(mode, payload = list()) {
  bin <- se_py_binary()
  if (is.null(bin) || !requireNamespace("jsonlite", quietly = TRUE)) return(NULL)
  runner <- file.path(se_bundle_root(), "app", "python", "run_engine.py")
  if (!file.exists(runner)) return(NULL)
  Sys.setenv(SE_SPACY_MODEL = getOption("se.spacy_model", "en_core_web_lg"))
  input <- jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null")
  out <- tryCatch(
    suppressWarnings(system2(bin, args = c(shQuote(runner), mode),
                             input = input, stdout = TRUE, stderr = FALSE)),
    error = function(e) NULL)
  if (is.null(out) || !length(out)) return(NULL)
  txt <- paste(out, collapse = "")
  if (!nzchar(trimws(txt))) return(NULL)
  tryCatch(jsonlite::fromJSON(txt, simplifyDataFrame = TRUE),
           error = function(e) NULL)
}

.se_empty_ner <- function() {
  data.frame(row=integer(0), start=integer(0), end=integer(0),
             match=character(0), type=character(0), identifier=character(0),
             detector=character(0), confidence=numeric(0), stringsAsFactors = FALSE)
}

#' Report availability passively (no subprocess, no network) — file existence
#' only. presidio/spacy/ollama are NA until an explicit se_py_probe().
se_py_status <- function() {
  if (!is.null(.se_py_state$status)) return(.se_py_state$status)
  bin <- se_py_binary()
  st <- list(python = !is.null(bin), python_path = bin %||% NA_character_,
             jsonlite = requireNamespace("jsonlite", quietly = TRUE),
             presidio = NA, spacy = NA, ollama = NA, onnx = NA, pf = NA,
             llm = NA, llm_backend = NA_character_)
  .se_py_state$status <- st
  st
}

#' Actively probe the bundled Python for the NER/LLM modules, out-of-process.
#' Only call this from an explicit user action ("Enable NER"), never at startup.
se_py_probe <- function() {
  st <- se_py_status()
  res <- .se_py_run("probe", list())
  if (is.null(res)) {           # no interpreter / failed -> stays unavailable
    st$presidio <- FALSE; st$spacy <- FALSE
  } else {
    st$presidio <- isTRUE(res$presidio)
    st$spacy    <- isTRUE(res$spacy)
  }
  st$onnx <- if (is.null(res)) FALSE else isTRUE(res$onnx)
  st$pf   <- isTRUE(st$onnx) && isTRUE(se_pf_config()$available)
  # LLM availability (either backend). llamacpp is file-existence only; ollama
  # additionally needs a client lib present (from the probe) and a model set.
  cfg <- se_llm_config()
  st$llm_backend <- cfg$backend
  st$llm <- !is.null(se_py_binary()) && switch(cfg$backend,
    llamacpp = nzchar(cfg$llama_bin) && file.exists(cfg$llama_bin) &&
               nzchar(cfg$model_path) && file.exists(cfg$model_path),
    ollama   = isTRUE(res$ollama) && nzchar(cfg$ollama_model),
    FALSE)
  st$ollama <- isTRUE(st$llm) && identical(cfg$backend, "ollama")  # legacy field
  .se_py_state$status <- st
  st
}

#' NER scan of a character vector. Returns a data.frame in the findings span
#' schema (row, start, end, match, type, identifier, detector, confidence) or an
#' empty frame if the engine is unavailable.
se_py_scan <- function(texts) {
  st <- se_py_status()
  if (!isTRUE(st$presidio) || !isTRUE(st$spacy)) return(.se_empty_ner())
  r <- .se_py_run("ner", list(texts = I(as.character(texts))))
  if (is.null(r) || !is.data.frame(r) || !nrow(r)) .se_empty_ner() else r
}

#' Privacy Filter model directory, discovered passively (file existence only —
#' never runs anything, never touches the network). options(se.pf_dir) /
#' SE_PF_DIR, else <bundle>/models/pf/. `available` requires an .onnx plus the
#' tokenizer and config next to it.
se_pf_config <- function() {
  dir <- getOption("se.pf_dir", Sys.getenv("SE_PF_DIR", ""))
  if (!nzchar(dir)) dir <- file.path(se_bundle_root(), "models", "pf")
  has_model <- dir.exists(dir) &&
    length(list.files(dir, pattern = "\\.onnx$", ignore.case = TRUE)) > 0L &&
    file.exists(file.path(dir, "tokenizer.json")) &&
    file.exists(file.path(dir, "config.json"))
  list(dir = dir, available = isTRUE(has_model))
}

#' Privacy Filter scan of a character vector via the bundled Python, out-of-
#' process (ONNX). Returns the findings span schema (row, start, end, match,
#' type, identifier, detector, confidence) or an empty frame. Fails closed.
se_pf_scan <- function(texts) {
  if (is.null(se_py_binary())) return(.se_empty_ner())
  cfg <- se_pf_config()
  if (!isTRUE(cfg$available)) return(.se_empty_ner())
  # I() keeps a single text an array (auto_unbox would collapse it to a scalar,
  # which the runner would then iterate character-by-character).
  r <- .se_py_run("pf", list(texts = I(as.character(texts)), model_dir = cfg$dir))
  if (is.null(r) || !is.data.frame(r) || !nrow(r)) .se_empty_ner() else r
}

#' Human-readable one-liner for the UI.
se_py_status_text <- function() {
  st <- se_py_status()
  if (!isTRUE(st$jsonlite)) return("Python NER: jsonlite not installed (rules-only mode).")
  if (!isTRUE(st$python)) return("Python NER: bundled interpreter not configured (rules-only mode).")
  if (isTRUE(st$presidio) && isTRUE(st$spacy)) {
    tail <- paste0(
      if (isTRUE(st$pf)) " · Privacy Filter ready." else "",
      if (isTRUE(st$llm)) paste0(" · local LLM (", st$llm_backend, ") available.")
      else if (!isTRUE(st$pf)) "." else "")
    return(paste0("Python NER: Presidio + spaCy ready", tail))
  }
  if (is.na(st$presidio)) return("Python NER: bundled interpreter found; click Enable NER to probe.")
  "Python NER: interpreter found but Presidio/spaCy model missing (rules-only mode)."
}

# ---------------------------------------------------------------------------
# Optional local LLM pass — OFF BY DEFAULT. Two local backends:
#
#   * llamacpp (RECOMMENDED for air-gap): a one-shot subprocess of a bundled
#     `llama-cli` against a bundled GGUF model. NO socket — same out-of-process
#     shape as NER. Zero-config: drop bin/llama/llama-cli(.exe) + a single
#     models/llm/*.gguf into the bundle and it is auto-discovered.
#   * ollama: a loopback call to a LOCAL Ollama the operator bundled and runs —
#     the ONLY socket in the whole system.
#
# The pure-R core opens no sockets itself; anything that could is confined to the
# opt-in Python layer (app/python/detect_llm.py), keeping the air-gap guarantee
# auditable in one place. Nothing here is touched unless the operator both
# bundles/configures a backend AND explicitly opts in per scan.
# ---------------------------------------------------------------------------

#' Ollama endpoint + model, read passively from options/env (no connection).
se_ollama_config <- function() {
  list(url   = getOption("se.ollama_url",   Sys.getenv("SE_OLLAMA_URL",   "http://127.0.0.1:11434")),
       model = getOption("se.ollama_model", Sys.getenv("SE_OLLAMA_MODEL", "")))
}

#' llama.cpp binary + GGUF model, discovered passively (file existence only).
#' Binary: options(se.llamacpp_bin) / SE_LLAMACPP_BIN, else <bundle>/bin/llama/.
#' Model:  options(se.llamacpp_model) / SE_LLAMACPP_MODEL, else the single .gguf
#'         under <bundle>/models/llm/. If several exist, preference order is
#'         MediPhi-Instruct (the recommended MEDICAL default — extraction-tuned,
#'         MIT, best free-text NAME recall in the A/B; see docs/ner_packaging.md)
#'         then Qwen2.5-3B (the license-clean generalist fallback).
se_llamacpp_config <- function() {
  root <- se_bundle_root()
  bin <- getOption("se.llamacpp_bin", Sys.getenv("SE_LLAMACPP_BIN", ""))
  if (!nzchar(bin)) {
    cand <- c(file.path(root, "bin", "llama", "llama-cli.exe"),
              file.path(root, "bin", "llama", "llama-cli"),
              file.path(root, "bin", "llama", "llama.exe"),
              file.path(root, "bin", "llama", "llama"))
    hit <- cand[file.exists(cand)]
    if (length(hit)) bin <- hit[1]
  }
  model <- getOption("se.llamacpp_model", Sys.getenv("SE_LLAMACPP_MODEL", ""))
  if (!nzchar(model)) {
    dir <- file.path(root, "models", "llm")
    g <- if (dir.exists(dir))
      list.files(dir, pattern = "\\.gguf$", full.names = TRUE, ignore.case = TRUE)
      else character(0)
    if (length(g) == 1L) {
      model <- g[1]
    } else if (length(g) > 1L) {
      # ordered preference when several are bundled: MediPhi (medical default)
      # then Qwen2.5-3B (generalist fallback); else ambiguous -> require choice.
      bn <- tolower(basename(g))
      pick <- ""
      for (pat in c("mediphi", "qwen2\\.5-3b", "qwen")) {
        hit <- g[grepl(pat, bn)]
        if (length(hit)) { pick <- hit[1]; break }
      }
      model <- pick
    }
  }
  list(bin = bin, model = model)
}

#' Resolve which LLM backend to use and its parameters. Explicit
#' options(se.llm_backend)/SE_LLM_BACKEND wins; otherwise auto-detect: prefer the
#' socket-free bundled llama.cpp, then a configured Ollama, else none ("").
se_llm_config <- function() {
  backend <- getOption("se.llm_backend", Sys.getenv("SE_LLM_BACKEND", ""))
  lc <- se_llamacpp_config()
  oc <- se_ollama_config()
  if (!nzchar(backend)) {
    backend <- if (nzchar(lc$bin) && nzchar(lc$model)) "llamacpp"
               else if (nzchar(oc$model)) "ollama" else ""
  }
  list(backend      = backend,
       llama_bin    = lc$bin,
       model_path   = lc$model,
       ollama_url   = oc$url,
       ollama_model = oc$model)
}

#' LLM scan of a character vector via the bundled Python (out-of-process).
#' Dispatches to the resolved backend. Returns the findings span schema, or an
#' empty frame if the backend is unavailable/unconfigured. Fails closed.
se_llm_scan <- function(texts) {
  if (is.null(se_py_binary())) return(.se_empty_ner())
  cfg <- se_llm_config()
  payload <- switch(cfg$backend,
    llamacpp = {
      if (!nzchar(cfg$llama_bin) || !file.exists(cfg$llama_bin) ||
          !nzchar(cfg$model_path) || !file.exists(cfg$model_path))
        return(.se_empty_ner())
      list(texts = I(as.character(texts)), backend = "llamacpp",
           llama_bin = cfg$llama_bin, model_path = cfg$model_path,
           # 1024 (not 512) so a batch's JSON completion doesn't truncate: a
           # medical SLM like MediPhi pretty-prints its output, inflating the
           # token count. The salvage parser tolerates any overflow, but the
           # headroom lets a typical free-text batch finish in one pass.
           n_predict = getOption("se.llm_n_predict", 1024L),
           ctx = getOption("se.llm_ctx", 4096L),
           batch = getOption("se.llm_batch", 16L))
    },
    ollama = {
      if (!nzchar(cfg$ollama_model)) return(.se_empty_ner())
      list(texts = I(as.character(texts)), backend = "ollama",
           model = cfg$ollama_model, url = cfg$ollama_url)
    },
    return(.se_empty_ner()))
  r <- .se_py_run("llm", payload)
  if (is.null(r) || !is.data.frame(r) || !nrow(r)) .se_empty_ner() else r
}

# ---------------------------------------------------------------------------
# Optional slm:jev pass — OFF BY DEFAULT. slm_jev (a separate checkout) proposes
# candidate spans with rules + shapes and asks a small local GGUF model typed
# questions, reading calibrated probabilities from option-token logprobs. It
# FAILS CLOSED: an unsure span comes back needs_review = TRUE and is redacted
# unless the reviewer rejects it (it bypasses the confidence floor). A failed
# scan is an error, never an empty result. Its only socket is loopback to the
# llama-server it starts itself.
# ---------------------------------------------------------------------------

#' slm_jev paths, discovered passively (file existence only).
#' root: options(se.slmjev_root) / SLMJEV_ROOT, else <bundle>/slmjev.
#' llama-server: options(se.slmjev_llama_server) / SLMJEV_LLAMA_SERVER, else
#'   <bundle>/bin/llama/llama-server(.exe). model: options(se.slmjev_model) /
#'   SLMJEV_JUDGE_MODEL, else <root>/models/judge.gguf. calibration:
#'   options(se.slmjev_calibration) / SLMJEV_CALIBRATION, else
#'   <root>/models/calibration.json (it must be fitted for that model).
se_jev_config <- function() {
  root <- getOption("se.slmjev_root", Sys.getenv("SLMJEV_ROOT", ""))
  if (!nzchar(root)) root <- file.path(se_bundle_root(), "slmjev")
  srv <- getOption("se.slmjev_llama_server", Sys.getenv("SLMJEV_LLAMA_SERVER", ""))
  if (!nzchar(srv)) {
    cand <- file.path(se_bundle_root(), "bin", "llama",
                      c("llama-server.exe", "llama-server"))
    hit <- cand[file.exists(cand)]
    if (length(hit)) srv <- hit[1]
  }
  model <- getOption("se.slmjev_model", Sys.getenv("SLMJEV_JUDGE_MODEL", ""))
  if (!nzchar(model)) model <- file.path(root, "models", "judge.gguf")
  cal <- getOption("se.slmjev_calibration", Sys.getenv("SLMJEV_CALIBRATION", ""))
  if (!nzchar(cal)) cal <- file.path(root, "models", "calibration.json")
  need <- c(slmjev = file.path(root, "slmjev", "engine.py"), llama_server = srv,
            model = model, calibration = cal)
  miss <- names(need)[!nzchar(need) | !file.exists(need)]
  list(root = normalizePath(root, "/", mustWork = FALSE),
       llama_server = if (nzchar(srv)) normalizePath(srv, "/", mustWork = FALSE) else srv,
       model = normalizePath(model, "/", mustWork = FALSE),
       calibration = normalizePath(cal, "/", mustWork = FALSE),
       available = !length(miss), missing = miss)
}

# slm_jev identifier -> this app's free-text `type` (the ft_types vocabulary)
.se_jev_types <- c(
  name = "name", national_id = "nric", mrn = "mrn", case_visit = "case",
  address = "address", postal_code = "postal", phone = "phone", fax = "phone",
  email = "email", dob = "date", date_of_death = "date", device = "serial",
  biometric = "biometric", photo = "photo", other_id = "other",
  hiv_sti = "sensitive", mental_health = "sensitive", substance_use = "sensitive",
  genetic = "sensitive", reproductive_sexual = "sensitive",
  other_sensitive = "sensitive")
.se_ft_types <- c("name", "address", "email", "phone", "date", "postal", "nric",
                  "passport", "mrn", "case", "ip", "url", "account", "secret",
                  "serial", "biometric", "photo", "other", "sensitive")

.se_empty_jev <- function() {
  e <- .se_empty_ner()
  e$needs_review <- logical(0); e$reasons <- character(0)
  e
}

#' Parsed slm_jev records -> the findings span schema plus needs_review/reasons.
#' Pure (no Python), so it is testable headlessly.
se_jev_frame <- function(r) {
  if (is.null(r) || !is.data.frame(r) || !nrow(r)) return(.se_empty_jev())
  ident <- as.character(r$identifier)
  jt <- as.character(r$type)
  # keep a type this app already knows (rule hints: nric, postal, case, ...);
  # else map the judged identifier; an unlabelled review span is "other"
  type <- ifelse(!is.na(jt) & jt %in% .se_ft_types, jt,
                 unname(.se_jev_types[ident]))
  type[is.na(type)] <- "other"
  conf <- suppressWarnings(as.numeric(r$confidence))
  conf[is.na(conf)] <- 0      # judge failed: no score, but needs_review holds it
  rev <- as.logical(r$needs_review)
  rev[is.na(rev)] <- TRUE
  reasons <- if (is.null(r$reasons)) rep("", nrow(r)) else
    vapply(r$reasons, function(x) paste(unlist(x), collapse = ";"), character(1))
  data.frame(row = as.integer(r$row), start = as.integer(r$start),
             end = as.integer(r$end), match = as.character(r$match), type = type,
             identifier = ifelse(is.na(ident), "other_id", ident),
             detector = "slm:jev", confidence = conf, needs_review = rev,
             reasons = reasons, stringsAsFactors = FALSE)
}

#' Engine spans for slm:jev to judge, one data.frame (start, end, type,
#' detector) per text: every Privacy Filter span plus Presidio `person` spans,
#' slm_jev's release configuration (its decision 0009). The judge decides on
#' each one; an engine span is never accepted just because an engine found it.
#' NULL when there is nothing to pass.
se_jev_candidates <- function(n, pf = NULL, ner = NULL) {
  keep <- c("row", "start", "end", "type", "detector")
  parts <- list()
  if (!is.null(pf) && nrow(pf)) parts$pf <- pf[, keep, drop = FALSE]
  if (!is.null(ner) && nrow(ner))
    parts$ner <- ner[ner$type %in% "person", keep, drop = FALSE]
  all <- do.call(rbind, c(list(.se_empty_ner()[, keep]), unname(parts)))
  if (!nrow(all)) return(NULL)
  lapply(seq_len(n), function(i) {
    x <- all[all$row == i, keep[-1], drop = FALSE]
    rownames(x) <- NULL
    x
  })
}

#' slm:jev scan of a character vector (out-of-process). Returns the findings
#' span schema plus needs_review/reasons. `candidates` (from
#' se_jev_candidates) adds engine spans for the judge to decide on. When
#' slm_jev is missing or the scan fails it returns an empty frame with
#' attr(, "error") set, and with strict = TRUE it stops instead: a
#' de-identification run must not quietly lose the detector the reviewer
#' approved.
se_jev_scan <- function(texts, kind = "text", column = NULL, strict = FALSE,
                        candidates = NULL) {
  fail <- function(msg) {
    if (strict) stop("slm:jev: ", msg, call. = FALSE)
    warning("slm:jev: ", msg, call. = FALSE)
    structure(.se_empty_jev(), error = msg)
  }
  if (is.null(se_py_binary())) return(fail("bundled Python interpreter not found"))
  cfg <- se_jev_config()
  if (!isTRUE(cfg$available))
    return(fail(paste("missing", paste(cfg$missing, collapse = ", "))))
  payload <- list(texts = I(as.character(texts)), kind = kind,
                  slmjev_root = cfg$root, llama_server = cfg$llama_server,
                  model = cfg$model, calibration = cfg$calibration)
  if (!is.null(column)) payload$column <- column
  if (!is.null(candidates)) {
    if (length(candidates) != length(texts))
      return(fail("candidates must have one entry per text"))
    payload$candidates <- candidates
  }
  r <- .se_py_run("jev", payload)
  if (is.null(r)) return(fail("no response from the engine"))
  if (is.list(r) && !is.data.frame(r) && !is.null(r$error))
    return(fail(as.character(r$error)))
  se_jev_frame(r)
}

# ---------------------------------------------------------------------------
# Free-text detection = deterministic rules (always) + optional offline NER +
# optional local LLM, merged into one findings table for the review screen.
# Pure enough to test headlessly: with use_ner/use_llm FALSE it is rules-only,
# and the NER/LLM engines fail closed to empty when their backends are absent.
# ---------------------------------------------------------------------------

#' Columns that look like free text (notes/remarks/comments/...).
se_freetext_columns <- function(cols) {
  cols[grepl("note|remark|comment|text|desc|free", tolower(cols))]
}

#' Merge/dedup findings in the app's free-text schema
#' (row, column, match, type, confidence, detector), keeping the
#' highest-confidence detector per (row, column, match, type).
se_dedup_findings <- function(df) {
  if (is.null(df) || !nrow(df)) return(df)
  k <- paste(df$row, df$column, tolower(df$match), df$type, sep = "\t")
  # a duplicate keeps the flag of any copy slm:jev was unsure of (fail closed)
  if (!is.null(df$needs_review))
    df$needs_review <- ave(df$needs_review %in% TRUE, k, FUN = any)
  df <- df[order(k, -df$confidence), , drop = FALSE]
  df <- df[!duplicated(paste(df$row, df$column, tolower(df$match), df$type,
                             sep = "\t")), , drop = FALSE]
  df <- df[order(df$row, df$column), , drop = FALSE]
  rownames(df) <- NULL
  df
}

#' Scan free-text columns of a data.frame. Returns
#' data.frame(row, column, match, type, confidence, detector, needs_review).
#' needs_review is TRUE only for slm:jev spans it is unsure of; a failed slm:jev
#' scan is reported in attr(, "jev_error").
se_detect_freetext <- function(df, ftcols = se_freetext_columns(names(df)),
                               use_pf = TRUE, use_ner = FALSE, use_llm = FALSE,
                               detectors = se_detectors(), use_jev = FALSE) {
  cols <- intersect(ftcols, names(df))
  out <- list()
  jev_err <- NULL
  add <- function(row, column, start, end, match, type, identifier,
                  confidence, detector, needs_review = FALSE) {
    if (length(match))
      out[[length(out) + 1L]] <<- data.frame(
        row = row, column = column, start = start, end = end, match = match,
        type = type, identifier = identifier, confidence = confidence,
        detector = detector, needs_review = needs_review,
        stringsAsFactors = FALSE)
  }
  for (cn in cols) {
    vals <- as.character(df[[cn]])
    # deterministic rules, per cell
    for (i in seq_along(vals)) {
      sp <- se_scan_text(vals[i], detectors)
      if (nrow(sp)) add(i, cn, sp$start, sp$end, sp$match, sp$type,
                        sp$identifier, sp$confidence, sp$detector)
    }
    # Privacy Filter (default), whole column vector (guards itself when absent).
    # slm:jev also judges its spans, so it runs for jev even when not shown.
    ps <- if (isTRUE(use_pf) || isTRUE(use_jev))
      tryCatch(se_pf_scan(vals), error = function(e) NULL)
    if (isTRUE(use_pf) && !is.null(ps) && nrow(ps))
      add(ps$row, cn, ps$start, ps$end, ps$match, ps$type,
          ps$identifier, ps$confidence, ps$detector)
    # legacy offline NER (opt-in); its person spans go to slm:jev once probed
    ns <- if (isTRUE(use_ner) || isTRUE(use_jev))
      tryCatch(se_py_scan(vals), error = function(e) NULL)
    if (isTRUE(use_ner) && !is.null(ns) && nrow(ns))
      add(ns$row, cn, ns$start, ns$end, ns$match, ns$type,
          ns$identifier, ns$confidence, ns$detector)
    # legacy local LLM (opt-in)
    if (isTRUE(use_llm)) {
      ls <- tryCatch(se_llm_scan(vals), error = function(e) NULL)
      if (!is.null(ls) && nrow(ls))
        add(ls$row, cn, ls$start, ls$end, ls$match, ls$type,
            ls$identifier, ls$confidence, ls$detector)
    }
    # slm:jev calibrated judge (opt-in); an error is reported, not swallowed
    if (isTRUE(use_jev)) {
      js <- tryCatch(suppressWarnings(
                       se_jev_scan(vals, candidates = se_jev_candidates(length(vals), ps, ns))),
                     error = function(e) structure(.se_empty_jev(),
                                                   error = conditionMessage(e)))
      if (!is.null(attr(js, "error"))) jev_err <- c(jev_err, attr(js, "error"))
      if (nrow(js))
        add(js$row, cn, js$start, js$end, js$match, js$type,
            js$identifier, js$confidence, js$detector, js$needs_review)
    }
  }
  res <- if (length(out)) do.call(rbind, out) else
    data.frame(row = integer(0), column = character(0), start = integer(0),
               end = integer(0), match = character(0), type = character(0),
               identifier = character(0), confidence = numeric(0),
               detector = character(0), needs_review = logical(0),
               stringsAsFactors = FALSE)
  res <- se_dedup_findings(res)
  if (length(jev_err)) attr(res, "jev_error") <- unique(jev_err)
  res
}
