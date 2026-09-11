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

# --- regex generalizer (learned_regex; suggestion-only) ---------------------
#' Abstract a set of literal values to a bounded character-class PCRE, anchored
#' with \b. Rejects over-broad patterns (matches too much corpus, or degenerate).
#' Returns list(pattern, coverage, false_positives) or NULL if unsafe.
se_autotune_generalize <- function(values, corpus = NULL, max_fp = 0L) {
  values <- unique(values[nzchar(values)])
  if (!length(values)) return(NULL)
  tok <- function(s) {
    chars <- strsplit(s, "")[[1]]
    cls <- ifelse(grepl("[0-9]", chars), "D",
           ifelse(grepl("[A-Za-z]", chars), "L", "S"))
    rle(cls)
  }
  rr <- lapply(values, tok)
  # require identical class-run structure across all values (a coherent shape)
  sig <- vapply(rr, function(r) paste(r$values, r$lengths, collapse = "|"),
                character(1))
  if (length(unique(sig)) != 1L) return(NULL)
  r <- rr[[1]]
  piece <- mapply(function(v, n) {
    base <- switch(v, D = "[0-9]", L = "[A-Za-z]", S = "[^A-Za-z0-9]")
    if (n == 1L) base else paste0(base, "{", n, "}")
  }, r$values, r$lengths)
  pat <- paste0("\\b", paste(piece, collapse = ""), "\\b")
  # specificity guard
  if (grepl("^\\\\b(\\.\\*)?\\\\b$", pat)) return(NULL)
  fp <- 0L
  if (!is.null(corpus) && length(corpus)) {
    corpus <- corpus[nzchar(corpus)]
    hit <- vapply(corpus, function(x) grepl(pat, x, perl = TRUE), logical(1))
    unintended <- setdiff(corpus[hit], values)
    fp <- length(unintended)
    if (length(corpus) && length(corpus[hit]) / length(corpus) > 0.5) return(NULL)
    if (fp > max_fp) return(NULL)
  }
  list(pattern = pat, coverage = 1, false_positives = fp)
}

# --- suggest ----------------------------------------------------------------
#' Aggregate diagnosed misses per identifier x cause (>= min_support), emit
#' ranked suggestions with a policy-patch delta and a safety preview.
se_autotune_suggest <- function(proj, data = NULL) {
  dg <- se_autotune_diagnose(proj)
  cfg <- se_autotune_config(proj)
  empty <- data.frame(id = character(0), identifier = character(0),
    lever = character(0), cause = character(0), support = integer(0),
    evidence = character(0), delta = character(0),
    new_detections = integer(0), false_positives = integer(0),
    stringsAsFactors = FALSE)
  if (!nrow(dg)) return(empty)
  out <- list()
  grp <- split(dg, paste(dg$identifier, dg$why_missed, sep = "\r"))
  for (gk in names(grp)) {
    g <- grp[[gk]]
    id <- g$identifier[1]; cause <- g$why_missed[1]; support <- nrow(g)
    if (support < cfg$min_support && cause != "below_threshold") next
    lever <- switch(cause,
      below_threshold = "threshold",
      wrong_column    = "column_enable",
      detector_off    = "column_enable",
      known_value     = "watchlist",
      no_pattern      = if (isTRUE(cfg$learned_regex)) "learned_regex" else "watchlist")
    delta <- switch(lever,
      threshold = {
        confs <- unlist(lapply(g$value, function(v) {
          h <- se_classify_value(v); if (length(h)) max(h) else 0.3 }))
        floor <- max(0.1, min(confs) - 0.05)
        list(lever = "threshold", identifier = id, floor = round(floor, 3))
      },
      watchlist = list(lever = "watchlist",
        pairs = lapply(unique(g$value), function(v)
          list(identifier = id, value = v))),
      column_enable = list(lever = "column_enable",
        column = g$column[1], detectors = list(id)),
      learned_regex = {
        gen <- se_autotune_generalize(g$value, corpus = NULL, max_fp = cfg$max_fp)
        if (is.null(gen)) list(lever = "watchlist",
          pairs = lapply(unique(g$value), function(v)
            list(identifier = id, value = v)))
        else list(lever = "learned_regex", identifier = id, pattern = gen$pattern)
      })
    lever <- delta$lever  # generalizer may have fallen back to watchlist
    saf <- .se_suggest_safety(delta, data)
    out[[length(out) + 1L]] <- data.frame(
      id = paste0("sg_", length(out) + 1L), identifier = id, lever = lever,
      cause = cause, support = support,
      evidence = paste(utils::head(unique(g$value), 3), collapse = ", "),
      delta = as.character(jsonlite::toJSON(delta, auto_unbox = TRUE)),
      new_detections = saf$new_detections, false_positives = saf$false_positives,
      stringsAsFactors = FALSE)
  }
  if (!length(out)) return(empty)
  res <- do.call(rbind, out)
  res[order(-res$support, res$false_positives), , drop = FALSE]
}

#' Safety preview: how many cells in `data` (a data.frame) the delta would newly
#' redact, and how many of those look like false positives (a value already
#' matching a shipped detector for a DIFFERENT identifier). Zero when no data.
.se_suggest_safety <- function(delta, data) {
  if (is.null(data) || !is.data.frame(data) || !ncol(data))
    return(list(new_detections = 0L, false_positives = 0L))
  extra <- switch(delta$lever,
    watchlist = se_watchlist_detector(do.call(rbind, lapply(delta$pairs,
      function(p) data.frame(identifier = p$identifier, value = p$value,
                             stringsAsFactors = FALSE)))),
    learned_regex = se_learned_detectors(list(list(identifier = delta$identifier,
                                                   pattern = delta$pattern))),
    list())
  det_base <- se_detectors()
  det_new  <- se_detectors(extra = extra)
  cells <- unlist(lapply(data, as.character), use.names = FALSE)
  cells <- cells[!is.na(cells) & nzchar(cells)]
  n_new <- 0L; n_fp <- 0L
  floor <- if (identical(delta$lever, "threshold")) delta$floor else 0.5
  for (cell in cells) {
    b <- se_scan_text(cell, det_base); a <- se_scan_text(cell, det_new)
    if (identical(delta$lever, "threshold")) {
      gained <- a[a$identifier == delta$identifier & a$confidence >= floor &
                  a$confidence < 0.5, , drop = FALSE]
    } else {
      gained <- a[!(paste(a$start, a$end, a$match) %in%
                    paste(b$start, b$end, b$match)), , drop = FALSE]
    }
    if (nrow(gained)) {
      n_new <- n_new + nrow(gained)
      for (j in seq_len(nrow(gained))) {
        ov <- b[b$start <= gained$end[j] & b$end >= gained$start[j], , drop=FALSE]
        if (nrow(ov)) n_fp <- n_fp + 1L
      }
    }
  }
  list(new_detections = as.integer(n_new), false_positives = as.integer(n_fp))
}

# --- apply / revert ---------------------------------------------------------
#' Merge approved suggestion deltas into policy: versioned, audited, reversible.
#' @param approved a data.frame subset of se_autotune_suggest() rows.
se_autotune_apply <- function(proj, approved, actor = "unknown") {
  if (is.null(approved) || !nrow(approved)) return(proj)
  tuning_id <- paste0("t", format(Sys.time(), "%Y%m%d%H%M%S"), "_",
                      as.integer(runif(1, 1, 1e6)))
  prior <- list(conf_overrides = proj$policy$conf_overrides %||% list(),
                learned_patterns = proj$policy$learned_patterns %||% list(),
                columns = proj$policy$columns %||% list(),
                watchlist = .se_watchlist_load(proj)$pairs)
  wl <- prior$watchlist
  deltas <- lapply(approved$delta, function(j) jsonlite::fromJSON(j,
                                                simplifyVector = FALSE))
  for (d in deltas) {
    switch(d$lever,
      threshold = {
        proj$policy$conf_overrides[[d$identifier]] <- as.numeric(d$floor)
      },
      watchlist = {
        add <- do.call(rbind, lapply(d$pairs, function(p) data.frame(
          identifier = p$identifier, value = p$value, stringsAsFactors = FALSE)))
        wl <- unique(rbind(wl, add))
      },
      column_enable = {
        col <- d$column
        spec <- proj$policy$columns[[col]] %||% list()
        spec$force_detectors <- unique(c(spec$force_detectors %||% character(0),
                                         unlist(d$detectors)))
        proj$policy$columns[[col]] <- spec
      },
      learned_regex = {
        proj$policy$learned_patterns[[length(proj$policy$learned_patterns)+1L]] <-
          list(identifier = d$identifier, pattern = d$pattern,
               tuning_id = tuning_id, added_by = actor,
               ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
      })
  }
  .se_watchlist_store(proj, list(pairs = wl))
  proj$policy$version <- (proj$policy$version %||% 1L) + 1L
  proj$policy$applied_tunings[[tuning_id]] <- list(
    tuning_id = tuning_id, ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    actor = actor, delta = deltas, prior = prior)
  se_project_save(proj)
  se_audit_append(se_project_paths(proj$dir)$audit, "feedback_tuning_applied",
                  actor, list(tuning_id = tuning_id,
                              levers = vapply(deltas, `[[`, character(1), "lever"),
                              version = proj$policy$version))
  proj
}

#' Undo a prior apply by restoring the pre-apply snapshot; audited.
se_autotune_revert <- function(proj, tuning_id, actor = "unknown") {
  ent <- proj$policy$applied_tunings[[tuning_id]]
  if (is.null(ent)) stop("no such tuning_id: ", tuning_id)
  proj$policy$conf_overrides   <- ent$prior$conf_overrides
  proj$policy$learned_patterns <- ent$prior$learned_patterns
  proj$policy$columns          <- ent$prior$columns
  .se_watchlist_store(proj, list(pairs = ent$prior$watchlist))
  proj$policy$applied_tunings[[tuning_id]] <- NULL
  proj$policy$version <- (proj$policy$version %||% 1L) + 1L
  se_project_save(proj)
  se_audit_append(se_project_paths(proj$dir)$audit, "feedback_tuning_reverted",
                  actor, list(tuning_id = tuning_id, version = proj$policy$version))
  proj
}
