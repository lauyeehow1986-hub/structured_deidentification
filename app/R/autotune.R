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

# --- diagnose ---------------------------------------------------------------
#' Classify each miss into why_missed, deterministically. Reuses the shipped
#' detectors via se_classify_value. min_conf floor defaults to 0.5 (the free-text
#' redaction default) unless a conf_override is set for that identifier.
se_autotune_diagnose <- function(proj, min_conf = 0.5) {
  fb <- se_feedback_read(proj)
  if (!nrow(fb)) return(fb)
  ov     <- proj$policy$conf_overrides %||% list()
  minsup <- se_autotune_config(proj)$min_support
  vlow   <- tolower(fb$value)
  counts <- table(vlow)
  for (i in seq_len(nrow(fb))) {
    val <- fb$value[i]; id <- fb$identifier[i]
    floor_i <- ov[[id]] %||% min_conf
    hits <- se_classify_value(val)              # named numeric: detector -> conf
    id_hit <- NA_real_
    if (length(hits)) {
      dd <- se_detectors()
      ids <- vapply(names(hits), function(n) dd[[n]]$identifier %||% NA_character_,
                    character(1))
      same <- hits[ids == id]
      if (length(same)) id_hit <- max(same)
      any_hit <- max(hits)
    } else any_hit <- NA_real_
    fb$why_missed[i] <-
      if (!is.na(id_hit) && id_hit >= floor_i)      "wrong_column"
      else if (!is.na(id_hit) && id_hit <  floor_i) "below_threshold"
      else if (counts[[vlow[i]]] >= minsup)          "known_value"
      else if (!is.na(any_hit))                      "detector_off"
      else                                           "no_pattern"
  }
  fb
}

# --- ground-truth ingest ----------------------------------------------------
#' Diff a gold table against detection to compute per-identifier recall and
#' record every uncovered gold item as a source="gold" miss.
#' @param gold data.frame(file, column, value, identifier).
#' @param inputs an se_batch_plan() data.frame (path,file,type), or NULL.
se_autotune_ingest_gold <- function(proj, gold, inputs = NULL,
                                    actor = "unknown") {
  stopifnot(all(c("file","column","value","identifier") %in% names(gold)))
  det <- se_autotune_detectors(proj)
  # collect the set of values detection WOULD catch across table inputs, lower-cased
  caught <- character(0)
  if (!is.null(inputs) && is.data.frame(inputs) && nrow(inputs)) {
    tbl <- inputs[inputs$type == "table", , drop = FALSE]
    for (path in tbl$path) {
      if (!file.exists(path) || !grepl("\\.csv$", path, ignore.case = TRUE)) next
      df <- tryCatch(utils::read.csv(path, stringsAsFactors = FALSE,
                                     colClasses = "character"),
                     error = function(e) NULL)
      if (is.null(df)) next
      for (cn in names(df)) for (cell in df[[cn]]) {
        if (is.na(cell) || !nzchar(cell)) next
        sp <- se_scan_text(cell, det)
        if (nrow(sp)) caught <- c(caught, tolower(sp$match))
      }
    }
  }
  caught <- unique(caught)
  covered <- tolower(gold$value) %in% caught
  # record misses
  for (i in which(!covered)) {
    se_feedback_record_miss(proj, file = gold$file[i], column = gold$column[i],
      row = NA_integer_, span = NULL, value = gold$value[i],
      identifier = gold$identifier[i], source = "gold", actor = actor)
  }
  # per-identifier recall
  agg <- lapply(split(covered, gold$identifier), function(v)
    c(n = length(v), hit = sum(v), recall = mean(v)))
  recall <- data.frame(identifier = names(agg),
                       n = vapply(agg, `[[`, numeric(1), "n"),
                       hit = vapply(agg, `[[`, numeric(1), "hit"),
                       recall = vapply(agg, `[[`, numeric(1), "recall"),
                       stringsAsFactors = FALSE, row.names = NULL)
  se_audit_append(se_project_paths(proj$dir)$audit, "feedback_gold_ingested",
                  actor, list(items = nrow(gold), missed = sum(!covered)))
  list(recall = recall, missed = sum(!covered))
}
