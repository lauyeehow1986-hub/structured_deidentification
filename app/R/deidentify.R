# deidentify.R — apply a de-identification policy to a tabular data.frame.
#
# Consumes a policy (column -> {identifier, action, options}) plus the resolved
# scope key, and returns:
#   data       the de-identified data.frame
#   crosswalk  data.frame(column, original, token) for reversible actions only
#              (pseudonymize / fpe), to be AEAD-encrypted for authorised re-id
#   summary    per-column action + counts, for the certificate/report
#
# Free-text columns use targeted redaction: only the spans the detectors flag
# are replaced (with a typed tag), the surrounding text is preserved.

# --- generalisation helpers --------------------------------------------------

se_generalize_date <- function(x, method = "year") {
  d <- suppressWarnings(as.Date(x, tryFormats = c("%d/%m/%Y","%Y-%m-%d","%m/%d/%Y","%d-%m-%Y")))
  out <- rep(NA_character_, length(x))
  ok <- !is.na(d)
  if (method == "year") out[ok] <- format(d[ok], "%Y")
  else if (method == "year_month") out[ok] <- format(d[ok], "%Y-%m")
  else out[ok] <- format(d[ok], "%Y")
  # values that didn't parse: leave a tag so nothing leaks silently
  out[!ok & !is.na(x)] <- "[DATE]"
  out
}

se_generalize_age <- function(x, width = 5L, cap = 90L) {
  a <- suppressWarnings(as.integer(x))
  out <- rep(NA_character_, length(x))
  ok <- !is.na(a)
  capped <- ok & a >= cap
  band <- ok & a < cap
  lo <- (a[band] %/% width) * width
  out[band] <- sprintf("%d-%d", lo, lo + width - 1L)
  out[capped] <- paste0(cap, "+")
  out
}

se_generalize_geo <- function(x, method = "region") {
  # SG postal sector = first 2 digits of a 6-digit code -> coarse district.
  vapply(x, function(v) {
    if (is.na(v)) return(NA_character_)
    m <- regmatches(v, regexpr("[0-9]{6}", v))
    if (length(m) == 1 && nzchar(m)) return(paste0("SECTOR-", substr(m, 1, 2)))
    "[GEO]"
  }, character(1), USE.NAMES = FALSE)
}

# Mask the last `mask_last` DIGITS of a value, preserving every non-digit char
# and any leading digits. This is the standard SG postal-code generalisation:
# keep the sector/area prefix, drop the precise last three that pinpoint the
# building/delivery point. "521123" -> "521XXX"; "Singapore 521123" ->
# "Singapore 521XXX". Non-numeric input is returned unchanged.
se_mask_postal <- function(x, mask_last = 3L, mask_char = "X") {
  vapply(x, function(v) {
    if (is.na(v)) return(NA_character_)
    v <- as.character(v)
    pos <- gregexpr("[0-9]", v)[[1]]
    if (pos[1] == -1L) return(v)
    k <- min(as.integer(mask_last), length(pos))
    if (k <= 0L) return(v)
    to_mask <- pos[(length(pos) - k + 1L):length(pos)]
    chars <- strsplit(v, "", fixed = TRUE)[[1]]
    chars[to_mask] <- mask_char
    paste(chars, collapse = "")
  }, character(1), USE.NAMES = FALSE)
}

# --- free-text targeted redaction -------------------------------------------

#' Replace only detected PII spans in a text with typed tags, keep the rest.
se_redact_freetext_value <- function(text, detectors = se_detectors(),
                                     min_conf = 0.5) {
  if (is.na(text) || !nzchar(text)) return(text)
  sp <- se_scan_text(text, detectors)
  sp <- sp[sp$confidence >= min_conf, , drop = FALSE]
  if (!nrow(sp)) return(text)
  sp <- se_dedup_overlaps(sp)
  # apply from rightmost span to leftmost so offsets stay valid
  sp <- sp[order(-sp$start), , drop = FALSE]
  out <- text
  for (i in seq_len(nrow(sp))) {
    matched <- substr(out, sp$start[i], sp$end[i])
    # postal codes are masked (keep sector, drop last 3) rather than dropped whole
    repl <- if (identical(sp$type[i], "postal")) se_mask_postal(matched)
            else paste0("[", toupper(sp$type[i]), "]")
    out <- paste0(substr(out, 1, sp$start[i] - 1L), repl,
                  substr(out, sp$end[i] + 1L, nchar(out)))
  }
  out
}

#' Redact a single free-text cell using a SUPPLIED span set (already filtered to
#' accepted spans above the confidence threshold). Right-to-left by offset so
#' positions stay valid; postal codes masked (keep sector), everything else
#' replaced by a typed tag. Pure — no detector call, no re-scan.
#' @param spans data.frame with columns start, end, type (1-based, inclusive).
se_redact_freetext_spans <- function(text, spans) {
  if (is.na(text) || !nzchar(text)) return(text)
  if (is.null(spans) || !nrow(spans)) return(text)
  # se_dedup_overlaps ranks by (width, confidence); supply a default so a
  # caller may pass a minimal start/end/type span set (no confidence column).
  if (is.null(spans$confidence)) spans$confidence <- 1
  spans <- se_dedup_overlaps(spans)
  spans <- spans[order(-spans$start), , drop = FALSE]
  out <- text
  for (i in seq_len(nrow(spans))) {
    s <- spans$start[i]; e <- spans$end[i]
    if (is.na(s) || is.na(e) || s < 1L || e < s || s > nchar(out)) next
    matched <- substr(out, s, e)
    # keep any trailing whitespace outside the tag so words stay separated
    trail <- sub("^.*?(\\s*)$", "\\1", matched)
    if (nzchar(trail)) {
      e <- e - nchar(trail)
      if (e < s) next
      matched <- substr(out, s, e)
    }
    repl <- if (identical(spans$type[i], "postal")) se_mask_postal(matched)
            else paste0("[", toupper(spans$type[i]), "]")
    out <- paste0(substr(out, 1, s - 1L), repl, substr(out, e + 1L, nchar(out)))
  }
  out
}

# --- main engine -------------------------------------------------------------

#' @param df       source data.frame (character columns recommended).
#' @param policy   list: columns = named list col -> list(identifier, action,
#'                 options=list(...)); freetext_columns = character().
#' @param key      resolved scope key (raw/character).
#' @param detectors detector registry (for free-text redaction).
se_deidentify_table <- function(df, policy, key, detectors = se_detectors()) {
  cols <- policy$columns %||% list()
  crosswalk <- list()
  summ <- list()
  out <- df

  for (cn in names(df)) {
    spec <- cols[[cn]]
    action <- spec$action %||% "keep"
    ident  <- spec$identifier %||% NA_character_
    opts   <- spec$options %||% list()
    ndef   <- se_identifier(ident)
    salt   <- ndef$salt %||% cn
    orig   <- as.character(df[[cn]])

    new <- switch(action,
      "pseudonymize" = {
        prefix <- toupper(substr(gsub("[^A-Za-z]", "", ident %||% cn), 1, 3))
        if (!nzchar(prefix) || prefix == "NA") prefix <- "ID"
        se_pseudonymize(orig, key, prefix = prefix, salt = salt)
      },
      "fpe" = {
        mode <- opts$fpe_mode %||% ndef$fpe_mode %||% "alnum_upper"
        vapply(orig, function(v) {
          if (is.na(v)) return(NA_character_)
          enc <- se_fpe(v, key, mode = mode, tweak = salt)
          if (is.na(enc)) se_pseudonymize(v, key, prefix="ID", salt=salt) else enc
        }, character(1), USE.NAMES = FALSE)
      },
      "generalize" = {
        meth <- opts$generalize %||% ndef$generalize %||% "year"
        if (meth %in% c("year","year_month")) se_generalize_date(orig, meth)
        else if (meth == "age_band")          se_generalize_age(orig, opts$width %||% 5L)
        else if (meth == "region")            se_generalize_geo(orig, "region")
        else if (meth == "postal_mask")       se_mask_postal(orig, opts$mask_last %||% 3L)
        else orig
      },
      "redact"          = ifelse(is.na(orig), NA_character_, "[REDACTED]"),
      "redact_freetext" = {
        fo <- policy$freetext_opts %||% NULL
        if (is.null(fo)) {
          # no policy-level review options -> legacy blind re-scan (ad-hoc use)
          vapply(orig, se_redact_freetext_value, character(1),
                 detectors = detectors, USE.NAMES = FALSE)
        } else {
          min_conf    <- fo$min_conf %||% 0.5
          types_allow <- fo$types    %||% NULL          # NULL = all types
          rejects     <- fo$rejects  %||% character(0)  # "col\ttype\ttolower(match)"
          pf_by_row <- NULL
          if (isTRUE(fo$use_pf)) {
            ps <- tryCatch(se_pf_scan(orig), error = function(e) NULL)
            if (!is.null(ps) && nrow(ps)) pf_by_row <- split(ps, ps$row)
          }
          keepcols <- c("start", "end", "match", "type", "identifier",
                        "detector", "confidence")
          vapply(seq_along(orig), function(i) {
            cell <- orig[i]
            if (is.na(cell) || !nzchar(cell)) return(cell)
            sp <- se_scan_text(cell, detectors)[, keepcols, drop = FALSE]
            if (!is.null(pf_by_row)) {
              pr <- pf_by_row[[as.character(i)]]
              if (!is.null(pr) && nrow(pr))
                sp <- rbind(sp, pr[, keepcols, drop = FALSE])
            }
            if (!nrow(sp)) return(cell)
            sp <- sp[sp$confidence >= min_conf, , drop = FALSE]
            if (!is.null(types_allow))
              sp <- sp[sp$type %in% types_allow, , drop = FALSE]
            if (length(rejects) && nrow(sp)) {
              kk <- paste(cn, sp$type, tolower(sp$match), sep = "\t")
              sp <- sp[!(kk %in% rejects), , drop = FALSE]
            }
            if (!nrow(sp)) return(cell)
            se_redact_freetext_spans(cell, sp)
          }, character(1), USE.NAMES = FALSE)
        }
      },
      "keep"            = orig,
      orig
    )
    out[[cn]] <- new

    # record reversible mappings for crosswalk
    if (action %in% c("pseudonymize","fpe")) {
      keep <- !is.na(orig) & nzchar(trimws(orig))
      if (any(keep)) {
        uniq <- !duplicated(orig[keep])
        crosswalk[[cn]] <- data.frame(
          column = cn, original = orig[keep][uniq], token = new[keep][uniq],
          stringsAsFactors = FALSE)
      }
    }
    summ[[cn]] <- list(column = cn, identifier = ident, action = action,
                       n_changed = sum(orig != new | (is.na(orig) != is.na(new)),
                                       na.rm = TRUE))
  }

  cw <- if (length(crosswalk)) do.call(rbind, crosswalk) else
        data.frame(column=character(0), original=character(0), token=character(0),
                   stringsAsFactors=FALSE)
  rownames(cw) <- NULL
  list(data = out, crosswalk = cw, summary = summ)
}
