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
             presidio = NA, spacy = NA, ollama = NA)
  .se_py_state$status <- st
  st
}

#' Actively probe the bundled Python for the NER/LLM modules, out-of-process.
#' Only call this from an explicit user action ("Enable NER"), never at startup.
se_py_probe <- function() {
  st <- se_py_status()
  res <- .se_py_run("probe", list())
  if (is.null(res)) {           # no interpreter / failed -> stays unavailable
    st$presidio <- FALSE; st$spacy <- FALSE; st$ollama <- FALSE
  } else {
    st$presidio <- isTRUE(res$presidio)
    st$spacy    <- isTRUE(res$spacy)
    # LLM backend usable only if a client lib is present AND a model configured.
    st$ollama   <- isTRUE(res$ollama) && nzchar(se_ollama_config()$model)
  }
  .se_py_state$status <- st
  st
}

#' NER scan of a character vector. Returns a data.frame in the findings span
#' schema (row, start, end, match, type, identifier, detector, confidence) or an
#' empty frame if the engine is unavailable.
se_py_scan <- function(texts) {
  st <- se_py_status()
  if (!isTRUE(st$presidio) || !isTRUE(st$spacy)) return(.se_empty_ner())
  r <- .se_py_run("ner", list(texts = as.character(texts)))
  if (is.null(r) || !is.data.frame(r) || !nrow(r)) .se_empty_ner() else r
}

#' Human-readable one-liner for the UI.
se_py_status_text <- function() {
  st <- se_py_status()
  if (!isTRUE(st$jsonlite)) return("Python NER: jsonlite not installed (rules-only mode).")
  if (!isTRUE(st$python)) return("Python NER: bundled interpreter not configured (rules-only mode).")
  if (isTRUE(st$presidio) && isTRUE(st$spacy)) {
    tail <- if (isTRUE(st$ollama)) " · local LLM available." else "."
    return(paste0("Python NER: Presidio + spaCy ready", tail))
  }
  if (is.na(st$presidio)) return("Python NER: bundled interpreter found; click Enable NER to probe.")
  "Python NER: interpreter found but Presidio/spaCy model missing (rules-only mode)."
}

# ---------------------------------------------------------------------------
# Optional local LLM (Ollama) pass — OFF BY DEFAULT.
#
# Everything here runs against a LOCAL Ollama service on this machine only, via
# the bundled Python (app/python/detect_llm.py). It is never touched unless the
# operator both (a) bundles an Ollama client + model and configures it, and
# (b) explicitly opts in per scan. The pure-R core opens no sockets itself; the
# only loopback call lives in the opt-in Python layer, keeping the air-gap
# guarantee auditable in one place.
# ---------------------------------------------------------------------------

#' Ollama endpoint + model, read passively from options/env (no connection).
se_ollama_config <- function() {
  list(url   = getOption("se.ollama_url",   Sys.getenv("SE_OLLAMA_URL",   "http://127.0.0.1:11434")),
       model = getOption("se.ollama_model", Sys.getenv("SE_OLLAMA_MODEL", "")))
}

#' LLM scan of a character vector via the bundled Python (out-of-process).
#' Returns the findings span schema, or an empty frame if the LLM backend is
#' unavailable/unconfigured. Fails closed.
se_llm_scan <- function(texts) {
  cfg <- se_ollama_config()
  if (is.null(se_py_binary()) || !nzchar(cfg$model)) return(.se_empty_ner())
  r <- .se_py_run("llm", list(texts = as.character(texts),
                              model = cfg$model, url = cfg$url))
  if (is.null(r) || !is.data.frame(r) || !nrow(r)) .se_empty_ner() else r
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
  df <- df[order(k, -df$confidence), , drop = FALSE]
  df <- df[!duplicated(paste(df$row, df$column, tolower(df$match), df$type,
                             sep = "\t")), , drop = FALSE]
  df <- df[order(df$row, df$column), , drop = FALSE]
  rownames(df) <- NULL
  df
}

#' Scan free-text columns of a data.frame. Returns
#' data.frame(row, column, match, type, confidence, detector).
se_detect_freetext <- function(df, ftcols = se_freetext_columns(names(df)),
                               use_ner = FALSE, use_llm = FALSE,
                               detectors = se_detectors()) {
  cols <- intersect(ftcols, names(df))
  out <- list()
  add <- function(row, column, match, type, confidence, detector) {
    if (length(match))
      out[[length(out) + 1L]] <<- data.frame(
        row = row, column = column, match = match, type = type,
        confidence = confidence, detector = detector, stringsAsFactors = FALSE)
  }
  for (cn in cols) {
    vals <- as.character(df[[cn]])
    # deterministic rules, per cell
    for (i in seq_along(vals)) {
      sp <- se_scan_text(vals[i], detectors)
      if (nrow(sp)) add(i, cn, sp$match, sp$type, sp$confidence, sp$detector)
    }
    # offline NER, whole column vector (guards itself when unavailable)
    if (isTRUE(use_ner)) {
      ns <- tryCatch(se_py_scan(vals), error = function(e) NULL)
      if (!is.null(ns) && nrow(ns))
        add(ns$row, cn, ns$match, ns$type, ns$confidence, ns$detector)
    }
    # optional local LLM (guards itself when unavailable / not opted in)
    if (isTRUE(use_llm)) {
      ls <- tryCatch(se_llm_scan(vals), error = function(e) NULL)
      if (!is.null(ls) && nrow(ls))
        add(ls$row, cn, ls$match, ls$type, ls$confidence, ls$detector)
    }
  }
  res <- if (length(out)) do.call(rbind, out) else
    data.frame(row = integer(0), column = character(0), match = character(0),
               type = character(0), confidence = numeric(0),
               detector = character(0), stringsAsFactors = FALSE)
  se_dedup_findings(res)
}
