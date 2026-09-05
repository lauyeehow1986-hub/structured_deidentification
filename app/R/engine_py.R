# engine_py.R — lazy bridge to the Python detection engine (Presidio + spaCy
# NER, and optional Ollama LLM). The R rule/validator engine (detect_r.R) always
# works with zero Python; this layer adds free-text NER when the bundled Python
# environment is present. Everything degrades gracefully on the air-gapped box:
# if Python or the model isn't there, we report "unavailable" and carry on with
# rules only.

.se_py_state <- new.env(parent = emptyenv())

#' Point reticulate at the bundled python if present, else the system one.
se_py_configure <- function(python = NULL) {
  if (!is.null(python) && file.exists(python)) {
    Sys.setenv(RETICULATE_PYTHON = python)
  }
  invisible(TRUE)
}

#' Path to a bundled/configured Python interpreter, or NULL. Checked by file
#' existence ONLY — never initialises reticulate and never touches the network
#' (critical on the air-gapped box, where reticulate's uv auto-provisioning
#' would otherwise try to fetch packages from PyPI).
se_py_binary <- function() {
  cand <- c(getOption("se.python", ""),
            Sys.getenv("SE_PYTHON", ""),
            file.path(se_bundle_root(), "bin", "python", "python.exe"),
            file.path(se_bundle_root(), "bin", "python", "bin", "python3"))
  cand <- cand[nzchar(cand)]
  hit <- cand[file.exists(cand)]
  if (length(hit)) hit[1] else NULL
}

#' Report availability passively (no Python init, no network).
se_py_status <- function() {
  if (!is.null(.se_py_state$status)) return(.se_py_state$status)
  bin <- se_py_binary()
  st <- list(reticulate = requireNamespace("reticulate", quietly = TRUE),
             python = !is.null(bin), python_path = bin %||% NA_character_,
             presidio = NA, spacy = NA, ollama = NA)
  .se_py_state$status <- st
  st
}

#' Actively probe the bundled Python for NER modules. Only call this from an
#' explicit user action ("Enable NER"), never at startup, and only when a
#' bundled interpreter exists. Sets RETICULATE_PYTHON to the bundled binary so
#' reticulate does NOT auto-provision an environment.
se_py_probe <- function() {
  bin <- se_py_binary()
  if (is.null(bin) || !requireNamespace("reticulate", quietly = TRUE)) return(se_py_status())
  Sys.setenv(RETICULATE_PYTHON = bin)
  st <- se_py_status()
  st$presidio <- tryCatch(reticulate::py_module_available("presidio_analyzer"),
                          error = function(e) FALSE)
  st$spacy    <- tryCatch(reticulate::py_module_available("spacy"),
                          error = function(e) FALSE)
  .se_py_state$status <- st
  st
}

#' NER scan of a character vector. Returns a data.frame in the findings span
#' schema (row, start, end, match, type, identifier, detector, confidence) or an
#' empty frame if the engine is unavailable.
se_py_scan <- function(texts) {
  st <- se_py_status()
  empty <- data.frame(row=integer(0), start=integer(0), end=integer(0),
                      match=character(0), type=character(0), identifier=character(0),
                      detector=character(0), confidence=numeric(0),
                      stringsAsFactors = FALSE)
  if (!isTRUE(st$presidio) || !isTRUE(st$spacy)) return(empty)
  tryCatch({
    reticulate::source_python(file.path(se_bundle_root(), "app", "python", "detect_ner.py"))
    res <- ner_scan(texts)             # defined in detect_ner.py
    reticulate::py_to_r(res)
  }, error = function(e) empty)
}

#' Human-readable one-liner for the UI.
se_py_status_text <- function() {
  st <- se_py_status()
  if (!st$reticulate) return("Python NER: reticulate not installed (rules-only mode).")
  if (!isTRUE(st$python)) return("Python NER: bundled interpreter not configured (rules-only mode).")
  if (isTRUE(st$presidio) && isTRUE(st$spacy)) return("Python NER: Presidio + spaCy ready.")
  if (is.na(st$presidio)) return("Python NER: bundled interpreter found; click Enable NER to probe.")
  "Python NER: interpreter found but Presidio/spaCy model missing (rules-only mode)."
}
