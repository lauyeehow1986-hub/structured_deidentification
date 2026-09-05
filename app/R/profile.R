# profile.R — column profiling + misplaced-PII / outlier detection.
#
# Two jobs the user asked for explicitly:
#   1. Flag values that don't fit their column (e.g. an NRIC typed into a
#      procedure-date or serial-number column) — a few outliers among many.
#   2. Flag columns whose *content* contradicts their declared type/name
#      (e.g. a column named "sn" that actually holds NRICs).
#
# Method: reduce each value to a compact "shape" signature, find the dominant
# shape per column, and treat rare shapes as structural outliers. Independently,
# run the deterministic classifiers on every cell so a high-confidence PII match
# (validated NRIC, email, card) sitting in a column whose majority is something
# else is surfaced as MISPLACED PII regardless of shape frequency.

#' Compact shape signature: digit->9, upper->A, lower->a, runs collapsed with a
#' length bucket so "123" and "1234" share a family but differ from "12".
se_value_shape <- function(v) {
  if (is.na(v)) return(NA_character_)
  s <- as.character(v)
  s <- gsub("[0-9]", "9", s)
  s <- gsub("[A-Z]", "A", s)
  s <- gsub("[a-z]", "a", s)
  # collapse runs of the same class to class+count-bucket
  chars <- strsplit(s, "")[[1]]
  if (!length(chars)) return("")
  out <- c(); run <- chars[1]; cnt <- 1L
  flush <- function(sym, n) paste0(sym, if (n>1) paste0("{", n, "}") else "")
  for (i in 2:length(chars)) {
    if (length(chars) < 2) break
    if (chars[i] == run) cnt <- cnt + 1L
    else { out <- c(out, flush(run, cnt)); run <- chars[i]; cnt <- 1L }
  }
  out <- c(out, flush(run, cnt))
  paste(out, collapse = "")
}

#' Profile one column.
#' @return list with dominant_shape, shape_table, dominant_type (majority PII
#'   classification or NA), and outliers: data.frame(row, value, reason, ...).
se_profile_column <- function(values, colname = "", high_risk =
                              c("nric","email","phone","creditcard","ip")) {
  n <- length(values)
  idx <- which(!is.na(values) & nzchar(trimws(as.character(values))))
  res <- list(colname = colname, dominant_shape = NA_character_,
              shape_table = integer(0), dominant_type = NA_character_,
              outliers = .se_prof_empty())
  if (length(idx) < 3) return(res)   # too few to reason about
  vv <- as.character(values[idx])

  # --- structural shapes ---
  shapes <- vapply(vv, se_value_shape, character(1))
  st <- sort(table(shapes), decreasing = TRUE)
  dom_shape <- names(st)[1]
  dom_frac <- as.numeric(st[1]) / length(vv)
  res$dominant_shape <- dom_shape
  res$shape_table <- st

  # --- content classification per cell ---
  cls <- lapply(vv, function(x) {
    h <- se_classify_value(x)
    if (!length(h)) return(NA_character_)
    names(h)[which.max(h)]
  })
  cls <- unlist(cls)
  ct <- table(cls[!is.na(cls)])
  # Only call a type "dominant" if it actually covers a majority of the whole
  # column; otherwise a lone misplaced value must not become the column's type.
  dom_type <- NA_character_
  if (length(ct)) {
    top <- names(sort(ct, decreasing = TRUE))[1]
    if (as.numeric(ct[top]) / length(vv) >= 0.5) dom_type <- top
  }
  res$dominant_type <- dom_type

  outliers <- list()
  for (j in seq_along(vv)) {
    row <- idx[j]
    val <- vv[j]
    this_type <- cls[j]
    this_shape <- shapes[j]
    reason <- NULL; sev <- NULL; ident <- NA_character_

    # (1) MISPLACED high-risk PII: cell is confidently a high-risk identifier
    #     but the column's majority is a different type (or untyped).
    if (!is.na(this_type) && this_type %in% high_risk) {
      col_mostly_this <- !is.na(dom_type) && identical(dom_type, this_type) &&
                         (as.numeric(ct[this_type]) / length(vv) >= 0.5)
      if (!col_mostly_this) {
        reason <- sprintf("Looks like %s but column is mostly %s",
                          this_type, ifelse(is.na(dom_type), "non-PII/other", dom_type))
        sev <- "high"; ident <- se_detectors()[[this_type]]$identifier
      }
    }
    # (2) STRUCTURAL outlier: rare shape in an otherwise-uniform column.
    if (is.null(reason) && dom_frac >= 0.7 && !identical(this_shape, dom_shape)) {
      cnt_this <- as.numeric(st[this_shape])
      if (cnt_this / length(vv) <= 0.1) {
        reason <- sprintf("Shape '%s' is unusual for this column (mostly '%s')",
                          this_shape, dom_shape)
        sev <- "medium"
        if (!is.na(this_type)) ident <- se_detectors()[[this_type]]$identifier
      }
    }
    if (!is.null(reason)) {
      outliers[[length(outliers)+1L]] <- data.frame(
        row=row, column=colname, value=val, reason=reason, severity=sev,
        identifier=ident, stringsAsFactors=FALSE)
    }
  }
  if (length(outliers)) res$outliers <- do.call(rbind, outliers)
  res
}

.se_prof_empty <- function()
  data.frame(row=integer(0), column=character(0), value=character(0),
             reason=character(0), severity=character(0), identifier=character(0),
             stringsAsFactors=FALSE)

#' Profile every column of a data.frame. Returns list(per_column=..., outliers=df).
se_profile_table <- function(df) {
  per <- list(); allout <- list()
  for (cn in names(df)) {
    p <- se_profile_column(df[[cn]], cn)
    per[[cn]] <- p
    if (nrow(p$outliers)) allout[[cn]] <- p$outliers
  }
  outliers <- if (length(allout)) do.call(rbind, allout) else .se_prof_empty()
  rownames(outliers) <- NULL
  list(per_column = per, outliers = outliers)
}
