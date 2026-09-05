# sdc.R — statistical disclosure control. Every measure here is OPT-IN; nothing
# runs unless the user enables it on the SDC tab.
#
# Core risk metrics are computed in pure R (robust, no fragile setup) with
# sdcMicro used opportunistically for individual risk when available. SOTA
# linkage risk (DCR / nearest-neighbour) follows the flexsynth approach.

#' k-anonymity summary over the chosen quasi-identifier columns.
#' Returns min group size (=k actually achieved), fraction of records in groups
#' smaller than the target k, and the count of unique (k=1) records.
se_kanon <- function(df, quasi_cols, k = 5L) {
  if (!length(quasi_cols)) return(NULL)
  quasi_cols <- intersect(quasi_cols, names(df))
  if (!length(quasi_cols)) return(NULL)
  key <- do.call(paste, c(df[quasi_cols], sep = "\r"))
  tab <- table(key)
  sizes <- as.integer(tab[key])
  list(
    quasi = quasi_cols,
    k_target = k,
    k_achieved = min(tab),
    n_unique = sum(tab == 1L),
    frac_below_k = mean(sizes < k),
    n_below_k = sum(sizes < k),
    group_sizes = tab
  )
}

#' l-diversity for a sensitive column within quasi groups: the minimum number of
#' distinct sensitive values across all groups (distinct l-diversity).
se_ldiversity <- function(df, quasi_cols, sensitive_col) {
  quasi_cols <- intersect(quasi_cols, names(df))
  if (!length(quasi_cols) || !sensitive_col %in% names(df)) return(NULL)
  key <- do.call(paste, c(df[quasi_cols], sep = "\r"))
  l <- tapply(df[[sensitive_col]], key, function(v) length(unique(v)))
  list(sensitive = sensitive_col, l_min = min(l), l_mean = mean(l))
}

#' Sample uniqueness (special uniques proxy / SUDA-lite): fraction of records
#' unique on the quasi set, and on every (k-1)-subset (higher = riskier).
se_sample_uniques <- function(df, quasi_cols) {
  quasi_cols <- intersect(quasi_cols, names(df))
  if (length(quasi_cols) < 1) return(NULL)
  key <- do.call(paste, c(df[quasi_cols], sep = "\r"))
  tab <- table(key)
  frac_full <- mean(as.integer(tab[key]) == 1L)
  # msu: minimal sample uniques over subsets of size length-1
  subs <- if (length(quasi_cols) > 1)
    combn(quasi_cols, length(quasi_cols) - 1L, simplify = FALSE) else list()
  sub_frac <- vapply(subs, function(cols) {
    k <- do.call(paste, c(df[cols], sep = "\r")); mean(as.integer(table(k)[k]) == 1L)
  }, numeric(1))
  list(frac_unique_full = frac_full,
       max_subset_unique = if (length(sub_frac)) max(sub_frac) else NA_real_)
}

#' Individual re-identification risk via sdcMicro, if the package cooperates.
se_individual_risk <- function(df, quasi_cols) {
  quasi_cols <- intersect(quasi_cols, names(df))
  if (!requireNamespace("sdcMicro", quietly = TRUE) || length(quasi_cols) < 1)
    return(NULL)
  tryCatch({
    d <- df[quasi_cols]
    for (c in names(d)) d[[c]] <- as.factor(d[[c]])
    obj <- sdcMicro::createSdcObj(dat = d, keyVars = names(d))
    r <- obj@risk$individual
    list(risk_mean = mean(r[, "risk"]), risk_max = max(r[, "risk"]),
         expected_reident = sum(r[, "risk"]))
  }, error = function(e) NULL)
}

#' SOTA linkage risk: distance-to-closest-record between de-identified output
#' and a reference (e.g. the original). Uses Gower-like mixed distance on the
#' quasi set. Small DCR => records sit close to real ones => higher risk.
se_dcr <- function(deid, reference, quasi_cols, sample_n = 500L) {
  quasi_cols <- intersect(quasi_cols, intersect(names(deid), names(reference)))
  if (length(quasi_cols) < 1) return(NULL)
  a <- deid[quasi_cols]; b <- reference[quasi_cols]
  if (nrow(a) > sample_n) a <- a[sample(nrow(a), sample_n), , drop = FALSE]
  # per-row min Hamming distance (fraction of mismatching quasi fields)
  d <- apply(a, 1L, function(row) {
    mism <- rowMeans(mapply(function(x, y) as.character(x) != as.character(y),
                            row, b) + 0)
    min(mism)
  })
  list(dcr_min = min(d), dcr_mean = mean(d),
       frac_zero = mean(d == 0))  # exact matches to a real record
}

#' Evaluate the configured export gate. Returns list(pass, reasons).
se_sdc_gate <- function(df, quasi_cols, thresholds = list(k = 5L, max_risk = 0.05)) {
  reasons <- character(0)
  ka <- se_kanon(df, quasi_cols, thresholds$k %||% 5L)
  if (!is.null(ka) && ka$k_achieved < (thresholds$k %||% 5L))
    reasons <- c(reasons, sprintf("k-anonymity %d < target %d (%d records below k)",
                                  ka$k_achieved, thresholds$k, ka$n_below_k))
  ir <- se_individual_risk(df, quasi_cols)
  if (!is.null(ir) && ir$risk_max > (thresholds$max_risk %||% 0.05))
    reasons <- c(reasons, sprintf("max individual risk %.3f > %.3f",
                                  ir$risk_max, thresholds$max_risk))
  list(pass = length(reasons) == 0, reasons = reasons, kanon = ka, risk = ir)
}
