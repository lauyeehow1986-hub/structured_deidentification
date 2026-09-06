# sdc_transforms.R — OPT-IN statistical-disclosure-control risk-reduction
# transforms. Nothing here runs unless the operator picks a transform on the SDC
# tab. These reduce re-identification risk (raise k, cut sample uniques) by
# coarsening or perturbing the quasi-identifiers, at a stated cost to utility.
#
# Design contract (every transform):
#   in : a data.frame + the column(s)/params to act on
#   out: list(data = <modified df>, note = <human-readable summary>,
#             n_changed = <count of cells/records altered>, op = <slug>)
# Pure R; no network, no external binary. Randomised transforms take an explicit
# `seed` so a treatment is reproducible and can be recorded in the audit trail
# (this mirrors sdcMicro's reproducible masking).
#
# Metrics live in sdc.R; this file only *changes* data. The SDC tab measures
# risk before and after so the operator sees the effect (e.g. k 1 -> 5).

# --- small helpers -----------------------------------------------------------

.se_num <- function(x) suppressWarnings(as.numeric(as.character(x)))

# Was the source column integer-valued? (so we can round perturbed output back.)
.se_is_intish <- function(x) {
  v <- .se_num(x); v <- v[!is.na(v)]
  length(v) > 0 && all(abs(v - round(v)) < 1e-9)
}

# Inverse-CDF Laplace draws (location 0). Uses the current RNG stream.
.se_rlaplace <- function(n, scale) {
  u <- stats::runif(n) - 0.5
  -scale * sign(u) * log(1 - 2 * abs(u))
}

.se_result <- function(df, note, n_changed, op) {
  list(data = df, note = note, n_changed = as.integer(n_changed), op = op)
}

# --- 1. local suppression ----------------------------------------------------

#' Local suppression: blank (NA) the quasi-identifier cells of every record that
#' falls in a quasi-group smaller than k. This is the classic last step that
#' forces k-anonymity — the rare combinations that make a record unique are
#' removed. By default all quasi columns of a below-k record are suppressed;
#' pass `cols` to suppress only the most-identifying one(s).
se_sdc_suppress <- function(df, quasi_cols, k = 5L, cols = NULL) {
  quasi_cols <- intersect(quasi_cols, names(df))
  if (!length(quasi_cols)) return(.se_result(df, "suppress: no quasi columns.", 0L, "suppress"))
  cols <- if (is.null(cols)) quasi_cols else intersect(cols, quasi_cols)
  key   <- do.call(paste, c(df[quasi_cols], sep = "\r"))
  sizes <- as.integer(table(key)[key])
  below <- which(sizes < k)
  n_changed <- 0L
  for (cn in cols) {
    hit <- below[!is.na(df[[cn]][below])]
    n_changed <- n_changed + length(hit)
    df[[cn]][below] <- NA
  }
  .se_result(df, sprintf("suppress: %d record(s) below k=%d; %d cell(s) blanked across %s.",
                         length(below), k, n_changed, paste(cols, collapse = ", ")),
             n_changed, "suppress")
}

# --- 2. global recode --------------------------------------------------------

#' Global recode: coarsen one column for every record. Numeric columns are cut
#' into bands (`breaks`, with optional `labels`); categorical columns are mapped
#' with `mapping` (a named character vector old -> new; unlisted levels are kept).
se_sdc_recode <- function(df, col, breaks = NULL, labels = NULL, mapping = NULL,
                          right = FALSE, include.lowest = TRUE) {
  if (!col %in% names(df)) return(.se_result(df, "recode: column not found.", 0L, "recode"))
  orig <- df[[col]]
  if (!is.null(breaks)) {
    v <- .se_num(orig)
    newv <- cut(v, breaks = breaks, labels = labels, right = right,
                include.lowest = include.lowest)
    newv <- as.character(newv)
    n_changed <- sum(!is.na(v))
    df[[col]] <- newv
    return(.se_result(df, sprintf("recode: '%s' cut into %d band(s).",
                                  col, length(breaks) - 1L), n_changed, "recode"))
  }
  if (!is.null(mapping)) {
    v <- as.character(orig)
    hit <- v %in% names(mapping)
    v[hit] <- unname(mapping[v[hit]])
    n_changed <- sum(hit, na.rm = TRUE)
    df[[col]] <- v
    return(.se_result(df, sprintf("recode: '%s' remapped %d level occurrence(s).",
                                  col, n_changed), n_changed, "recode"))
  }
  .se_result(df, "recode: nothing to do (give breaks or mapping).", 0L, "recode")
}

# --- 3. top / bottom coding --------------------------------------------------

#' Top/bottom coding: cap extreme numeric values (which are often uniquely
#' identifying) at a threshold. Give a percentile (`top_pct`/`bottom_pct`, e.g.
#' 0.01 to cap the top/bottom 1%) or an absolute cut (`top`/`bottom`).
se_sdc_topbottom <- function(df, col, top_pct = NULL, bottom_pct = NULL,
                             top = NULL, bottom = NULL) {
  if (!col %in% names(df)) return(.se_result(df, "topbottom: column not found.", 0L, "topbottom"))
  v <- .se_num(df[[col]])
  if (all(is.na(v))) return(.se_result(df, "topbottom: column not numeric.", 0L, "topbottom"))
  if (is.null(top)    && !is.null(top_pct))    top    <- as.numeric(stats::quantile(v, 1 - top_pct, na.rm = TRUE))
  if (is.null(bottom) && !is.null(bottom_pct)) bottom <- as.numeric(stats::quantile(v, bottom_pct,   na.rm = TRUE))
  n_changed <- 0L
  if (!is.null(top))    { hit <- which(v > top);    n_changed <- n_changed + length(hit); v[hit] <- top }
  if (!is.null(bottom)) { hit <- which(v < bottom); n_changed <- n_changed + length(hit); v[hit] <- bottom }
  df[[col]] <- v
  .se_result(df, sprintf("topbottom: '%s' capped%s%s; %d value(s) coded.", col,
                         if (!is.null(top)) sprintf(" top@%.4g", top) else "",
                         if (!is.null(bottom)) sprintf(" bottom@%.4g", bottom) else "",
                         n_changed), n_changed, "topbottom")
}

# --- 4. microaggregation -----------------------------------------------------

#' Microaggregation (individual ranking): for each numeric column, sort the
#' values, form consecutive groups of size `aggr`, and replace every value in a
#' group by the group mean (or median). Guarantees each released value is shared
#' by >= aggr records. A short final group is merged into the previous one so no
#' record is left in a singleton.
se_sdc_microaggregate <- function(df, cols, aggr = 3L, method = c("mean", "median")) {
  method <- match.arg(method)
  cols <- intersect(cols, names(df))
  aggr <- max(2L, as.integer(aggr))
  n_changed <- 0L; used <- character(0)
  fagg <- if (method == "mean") function(z) mean(z, na.rm = TRUE) else function(z) stats::median(z, na.rm = TRUE)
  for (cn in cols) {
    v <- .se_num(df[[cn]])
    idx <- order(v, na.last = NA)          # positions of non-NA in ascending order
    if (length(idx) < aggr) next
    g <- ((seq_along(idx) - 1L) %/% aggr) + 1L
    ng <- max(g)
    if (ng > 1L && sum(g == ng) < aggr) g[g == ng] <- ng - 1L   # merge short tail
    agg <- tapply(v[idx], g, fagg)
    newv <- v
    newv[idx] <- as.numeric(agg[as.character(g)])
    if (.se_is_intish(df[[cn]])) newv <- round(newv)
    n_changed <- n_changed + sum(newv[idx] != v[idx], na.rm = TRUE)
    df[[cn]] <- newv; used <- c(used, cn)
  }
  .se_result(df, sprintf("microaggregate: %s of groups of %d over %s.",
                         method, aggr, if (length(used)) paste(used, collapse = ", ") else "(no numeric column)"),
             n_changed, "microaggregate")
}

# --- 5. PRAM (post-randomisation) --------------------------------------------

#' PRAM: for a categorical column, keep each value with probability `retain`,
#' otherwise redraw a new level from the column's own marginal distribution. This
#' injects deniability into a categorical quasi-identifier while preserving the
#' overall distribution in expectation. Reproducible via `seed`.
se_sdc_pram <- function(df, col, retain = 0.8, seed = 1L) {
  if (!col %in% names(df)) return(.se_result(df, "pram: column not found.", 0L, "pram"))
  old <- as.character(df[[col]])
  present <- !is.na(old)
  if (!any(present)) return(.se_result(df, "pram: column all missing.", 0L, "pram"))
  probs <- prop.table(table(old[present]))
  set.seed(seed)
  redraw <- present & (stats::runif(length(old)) >= retain)
  v <- old
  if (any(redraw))
    v[redraw] <- sample(names(probs), sum(redraw), replace = TRUE, prob = as.numeric(probs))
  n_changed <- sum(v != old, na.rm = TRUE)
  df[[col]] <- v
  .se_result(df, sprintf("pram: '%s' retain=%.2f; %d value(s) changed.", col, retain, n_changed),
             n_changed, "pram")
}

# --- 6. noise addition (incl. DP-style Laplace) ------------------------------

#' Additive noise for numeric quasi-identifiers.
#'   method = "gaussian": add N(0, (pct * sd)^2) to each value.
#'   method = "laplace" : add Laplace noise. If `epsilon` is given the column is
#'     first clamped to [lower, upper] (defaults to the data range) and the noise
#'     scale is (upper-lower)/epsilon — a DP-style calibrated Laplace mechanism.
#'     Otherwise the scale is pct * sd. Integer columns are rounded back.
#' NOTE: the Laplace/epsilon form is a per-value Laplace mechanism; formal
#' (epsilon)-DP for a *released microdata table* additionally requires bounding
#' each individual's contribution across the release — see docs. It is offered
#' here as a strong, calibrated perturbation, not a table-level DP guarantee.
se_sdc_noise <- function(df, cols, method = c("gaussian", "laplace"),
                         pct = 0.1, epsilon = NULL, lower = NULL, upper = NULL, seed = 1L) {
  method <- match.arg(method)
  cols <- intersect(cols, names(df))
  set.seed(seed)
  n_changed <- 0L; used <- character(0)
  for (cn in cols) {
    v <- .se_num(df[[cn]]); ok <- !is.na(v)
    if (!any(ok)) next
    s <- stats::sd(v[ok])
    if (method == "gaussian") {
      noise <- stats::rnorm(sum(ok), 0, (pct %||% 0.1) * s)
    } else {
      if (!is.null(epsilon) && epsilon > 0) {
        lo <- lower %||% min(v[ok]); hi <- upper %||% max(v[ok])
        v[ok] <- pmin(pmax(v[ok], lo), hi)
        scale <- (hi - lo) / epsilon
      } else scale <- (pct %||% 0.1) * s
      noise <- .se_rlaplace(sum(ok), scale)
    }
    v[ok] <- v[ok] + noise
    if (.se_is_intish(df[[cn]])) v <- round(v)
    df[[cn]] <- v
    n_changed <- n_changed + sum(ok); used <- c(used, cn)
  }
  lab <- if (method == "laplace" && !is.null(epsilon)) sprintf("laplace eps=%.3g", epsilon)
         else sprintf("%s pct=%.2f", method, pct %||% 0.1)
  .se_result(df, sprintf("noise: %s over %s; %d value(s) perturbed.",
                         lab, if (length(used)) paste(used, collapse = ", ") else "(none)", n_changed),
             n_changed, "noise")
}

# --- 7. synthetic replacement (optional) -------------------------------------

#' Is the author's flexsynth package available for high-utility (joint-
#' preserving) synthesis? If not, a simpler pure-R marginal resynthesis is used.
se_sdc_synth_available <- function() requireNamespace("flexsynth", quietly = TRUE)

#' Independent marginal resynthesis: replace the quasi columns with fresh draws
#' from each column's own marginal (row order preserved for the other columns).
#' This breaks the *joint* quasi combination so no released row corresponds to a
#' real person's quasi profile — a low-utility but dependency-free synthetic
#' option. For joint-preserving synthesis install flexsynth and use
#' se_sdc_synth_flexsynth().
se_sdc_synth_marginal <- function(df, cols, seed = 1L) {
  cols <- intersect(cols, names(df))
  if (!length(cols)) return(.se_result(df, "synth: no columns.", 0L, "synth"))
  set.seed(seed)
  n <- nrow(df)
  for (cn in cols) {
    v <- df[[cn]]; ok <- !is.na(v)
    if (!any(ok)) next
    df[[cn]] <- sample(v[ok], n, replace = TRUE)
  }
  .se_result(df, sprintf("synth (marginal): %s resampled independently (joint combination broken).",
                         paste(cols, collapse = ", ")), n, "synth")
}

#' Joint-preserving synthesis via the author's flexsynth package, when installed.
#' Falls back to marginal resynthesis (with a note) when flexsynth is absent.
se_sdc_synth_flexsynth <- function(df, cols = names(df), seed = 1L, ...) {
  if (!se_sdc_synth_available())
    return(se_sdc_synth_marginal(df, cols, seed = seed))
  cols <- intersect(cols, names(df))
  out <- tryCatch({
    set.seed(seed)
    syn <- flexsynth::synth(df[cols], ...)
    sdat <- if (is.data.frame(syn)) syn else syn$data %||% syn$syn %||% syn[[1]]
    d <- df
    for (cn in intersect(cols, names(sdat))) d[[cn]] <- sdat[[cn]][seq_len(nrow(d))]
    d
  }, error = function(e) NULL)
  if (is.null(out)) return(se_sdc_synth_marginal(df, cols, seed = seed))
  .se_result(out, sprintf("synth (flexsynth): %s synthesised (joint structure modelled).",
                          paste(cols, collapse = ", ")), nrow(out), "synth")
}

# --- transform stack / dispatcher --------------------------------------------

#' Apply a sequence of transform specs to a data.frame, returning the treated
#' data and a log. Each step is list(op = <slug>, args = list(...)); the df is
#' threaded through automatically (do not put it in args). Used to reproduce a
#' recorded treatment and to drive the SDC tab.
se_sdc_apply <- function(df, steps) {
  log <- character(0)
  fns <- list(
    suppress       = se_sdc_suppress,
    recode         = se_sdc_recode,
    topbottom      = se_sdc_topbottom,
    microaggregate = se_sdc_microaggregate,
    pram           = se_sdc_pram,
    noise          = se_sdc_noise,
    synth          = se_sdc_synth_marginal
  )
  for (st in steps) {
    fn <- fns[[st$op]]
    if (is.null(fn)) { log <- c(log, sprintf("(skipped unknown op '%s')", st$op)); next }
    res <- do.call(fn, c(list(df), st$args))
    df <- res$data; log <- c(log, res$note)
  }
  list(data = df, log = log)
}
