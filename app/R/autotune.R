# autotune.R — feedback-driven detection tuning (Phase 9).
#
# Loop: capture -> diagnose -> suggest -> (reviewer approves) -> apply -> detect,
# with optional promote -> aggregate-only global register. Pure R, offline,
# deterministic. Raw missed values + the watchlist are PHI: they live ONLY in the
# project folder, AEAD-encrypted under the project key (crypto.R). The global
# register is aggregate-only and never stores a literal value.

# --- config / paths ---------------------------------------------------------
se_autotune_defaults <- function() {
  list(global_register = FALSE, learned_regex = FALSE,
       global_register_dir = NULL, min_support = 2L, max_fp = 0L)
}

#' Merge project autotune settings over the defaults.
se_autotune_config <- function(proj) {
  d <- se_autotune_defaults()
  a <- proj$policy$autotune %||% list()
  for (k in names(d)) if (!is.null(a[[k]])) d[[k]] <- a[[k]]
  d$min_support <- as.integer(d$min_support)
  d$max_fp      <- as.integer(d$max_fp)
  d
}

se_autotune_paths <- function(proj_dir) {
  list(feedback  = file.path(proj_dir, "feedback.enc"),
       watchlist = file.path(proj_dir, "watchlist.enc"))
}

# --- encrypted stores (project-scoped, PHI) ---------------------------------
.se_feedback_load <- function(proj) {
  pa <- se_autotune_paths(proj$dir)
  if (!file.exists(pa$feedback)) return(list(records = list()))
  key <- se_get_project_key(proj)
  se_blob_decrypt(readRDS(pa$feedback), key, "feedback")
}

.se_feedback_store <- function(proj, obj) {
  pa  <- se_autotune_paths(proj$dir)
  key <- se_get_project_key(proj)
  saveRDS(se_blob_encrypt(obj, key, "feedback"), pa$feedback)
  invisible(pa$feedback)
}

.se_watchlist_load <- function(proj) {
  pa <- se_autotune_paths(proj$dir)
  if (!file.exists(pa$watchlist))
    return(list(pairs = data.frame(identifier = character(0),
                                   value = character(0),
                                   stringsAsFactors = FALSE)))
  key <- se_get_project_key(proj)
  se_blob_decrypt(readRDS(pa$watchlist), key, "watchlist")
}

.se_watchlist_store <- function(proj, obj) {
  pa  <- se_autotune_paths(proj$dir)
  key <- se_get_project_key(proj)
  saveRDS(se_blob_encrypt(obj, key, "watchlist"), pa$watchlist)
  invisible(pa$watchlist)
}

# --- capture ----------------------------------------------------------------
#' Record one missed identifier (false negative). Appends an encrypted record and
#' writes a hash-chained audit event. `span` is c(start,end) or NULL.
se_feedback_record_miss <- function(proj, file, column, row, span, value,
                                    identifier, source = "reviewer",
                                    actor = "unknown", run_id = NA_character_) {
  st <- if (is.null(span)) NA_integer_ else as.integer(span[1])
  en <- if (is.null(span)) NA_integer_ else as.integer(span[2])
  rec <- list(ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), actor = actor,
              source = source, file = file, column = column,
              row = if (is.null(row)) NA_integer_ else as.integer(row),
              start = st, end = en, value = as.character(value),
              identifier = identifier, why_missed = NA_character_,
              run_id = run_id, tuning_id = NA_character_)
  store <- .se_feedback_load(proj)
  store$records[[length(store$records) + 1L]] <- rec
  .se_feedback_store(proj, store)
  se_audit_append(se_project_paths(proj$dir)$audit, "feedback_miss_marked",
                  actor, list(file = file, column = column,
                              identifier = identifier, source = source))
  invisible(proj)
}

#' Decrypt the feedback store into a flat data.frame (0-row df when empty).
se_feedback_read <- function(proj) {
  recs <- .se_feedback_load(proj)$records
  cols <- c("ts","actor","source","file","column","row","start","end",
            "value","identifier","why_missed","run_id","tuning_id")
  if (!length(recs)) {
    z <- as.data.frame(setNames(rep(list(character(0)), length(cols)), cols),
                       stringsAsFactors = FALSE)
    z$row <- integer(0); z$start <- integer(0); z$end <- integer(0)
    return(z)
  }
  do.call(rbind, lapply(recs, function(r) {
    r[vapply(r, is.null, logical(1))] <- NA
    as.data.frame(r[cols], stringsAsFactors = FALSE)
  }))
}

# --- augmented detector assembly --------------------------------------------
#' Shipped detectors + this project's watchlist + learned patterns. Used by the
#' batch/deidentify scan, the gold diff, and the suggestion safety preview.
se_autotune_detectors <- function(proj, postal6 = getOption("se.detect_postal6",
                                                            FALSE)) {
  wl <- tryCatch(.se_watchlist_load(proj)$pairs, error = function(e) NULL)
  extra <- c(se_watchlist_detector(wl),
             se_learned_detectors(proj$policy$learned_patterns %||% list()))
  se_detectors(postal6 = postal6, extra = extra)
}
