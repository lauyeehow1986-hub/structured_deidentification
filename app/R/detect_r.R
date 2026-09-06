# detect_r.R — deterministic, explainable PII detectors (rules + validators).
#
# These run in pure R, need no model weights, and produce the same findings
# schema as the Python NER/LLM detectors so everything merges into one review.
# Each detector: a regex to locate candidates, plus an optional validator that
# confirms a candidate (e.g. the NRIC check digit) to lift confidence and cut
# false positives.

# --- Singapore NRIC / FIN check-digit validator ------------------------------
# Weights 2,7,6,5,4,3,2 over the 7 digits; offset by series; lookup table by
# series. S/T (citizens/PR) and F/G (foreigners) are exact; M (2022+ FIN) is
# validated best-effort.

se_nric_valid <- function(x) {
  x <- toupper(trimws(as.character(x)))
  if (is.na(x) || !grepl("^[STFGM][0-9]{7}[A-Z]$", x)) return(FALSE)
  prefix <- substr(x, 1, 1)
  digits <- as.integer(strsplit(substr(x, 2, 8), "")[[1]])
  chk <- substr(x, 9, 9)
  w <- c(2, 7, 6, 5, 4, 3, 2)
  total <- sum(digits * w)
  if (prefix %in% c("T", "G")) total <- total + 4
  if (prefix == "M")          total <- total + 3
  st  <- c("J","Z","I","H","G","F","E","D","C","B","A")
  fg  <- c("X","W","U","T","R","Q","P","N","M","L","K")
  mm  <- c("K","L","J","N","P","Q","R","T","U","W","X")
  r <- total %% 11
  expected <- switch(prefix,
    "S" = st[r + 1L], "T" = st[r + 1L],
    "F" = fg[r + 1L], "G" = fg[r + 1L],
    "M" = mm[(10L - r) + 1L],
    NA_character_)
  identical(chk, expected)
}

# --- compact (separator-less) date parser ------------------------------------
# Parse a run of exactly 8 digits (optionally followed by a HHMMSS time, e.g.
# "19901231 143000" / "19901231T143000" — the DICOM/ECG-XML native forms) as a
# calendar date, trying yyyymmdd, then ddmmyyyy, then mmddyyyy. Returns a Date
# (date part only) or NA.
#
# The length gate is essential: R's as.Date("%Y%m%d") is greedy/lenient on the
# wrong number of digits (e.g. "1990123" -> 1990-12-03; a trailing digit is
# silently dropped), so a 7- or 9-digit serial would be mis-read as a date. We
# only ever feed it an anchored, exactly-8-digit string, and require a plausible
# calendar year (1900-2100) so an id like "01020304" (year 0102) is rejected.
se_parse_compact_date <- function(s) {
  s <- trimws(as.character(s))
  m <- regmatches(s, regexec("^([0-9]{8})(?:[ T][0-9]{6})?$", s))[[1]]
  if (length(m) < 2L) return(as.Date(NA))
  d8 <- m[2]
  for (f in c("%Y%m%d", "%d%m%Y", "%m%d%Y")) {
    dd <- suppressWarnings(as.Date(d8, format = f))
    if (!is.na(dd)) {
      yr <- as.integer(format(dd, "%Y"))
      if (!is.na(yr) && yr >= 1900L && yr <= 2100L) return(dd)
    }
  }
  as.Date(NA)
}

# --- detector registry -------------------------------------------------------
# pattern: PCRE regex (case-insensitive applied by scanner)
# validate: optional function(match_string) -> logical
# base_conf: confidence when matched (raised to ~0.99 when a validator passes)

#' @param postal6 opt-in: also treat a BARE 6-digit number as a possible SG
#'   postal code (low confidence — 6-digit runs are ambiguous). Off by default;
#'   the global default is read from options(se.detect_postal6). When on, matched
#'   postal codes are generalised by masking the last 3 digits (see se_mask_postal).
se_detectors <- function(postal6 = getOption("se.detect_postal6", FALSE)) {
  d <- list(
    nric = list(type="nric", identifier="national_id",
                pattern="\\b[STFGMstfgm][0-9]{7}[A-Za-z]\\b",
                validate=se_nric_valid, base_conf=0.6),
    email = list(type="email", identifier="email",
                 pattern="\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b",
                 validate=NULL, base_conf=0.97),
    phone = list(type="phone", identifier="phone",
                 # SG mobile/landline 8 digits, optional +65, spaces/dashes
                 pattern="(?<![0-9])(?:\\+?65[ -]?)?[3689][0-9]{3}[ -]?[0-9]{4}(?![0-9])",
                 validate=NULL, base_conf=0.7),
    postal = list(type="postal", identifier="postal_code",
                  pattern="\\bSingapore\\s+[0-9]{6}\\b|\\bS\\(?[0-9]{6}\\)?\\b",
                  validate=NULL, base_conf=0.6),
    date = list(type="date", identifier="dob",
                pattern="\\b(?:[0-3]?[0-9][/-][0-1]?[0-9][/-](?:19|20)[0-9]{2}|(?:19|20)[0-9]{2}[/-][0-1]?[0-9][/-][0-3]?[0-9])\\b",
                validate=NULL, base_conf=0.75),
    # separator-less 8-digit dates (ddmmyyyy/mmddyyyy/yyyymmdd) and the
    # DICOM/ECG-XML "yyyymmdd hhmmss" datetime. The regex only proposes 8-digit
    # (optionally +time) candidates; the validator confirms a real calendar date
    # so arbitrary 8-digit ids/phones are NOT flagged (conf drops to 0.15). A
    # confirmed date scores 0.99, beating the loose mrn catch-all on the same run.
    date_compact = list(type="date", identifier="dob",
                pattern="\\b[0-9]{8}(?:[ T][0-9]{6})?\\b",
                validate=function(m) !is.na(se_parse_compact_date(m)),
                base_conf=0.55),
    url = list(type="url", identifier="other_id",
               pattern="\\bhttps?://[^\\s]+\\b",
               validate=NULL, base_conf=0.95),
    ip = list(type="ip", identifier="other_id",
              pattern="\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b",
              validate=function(m){o<-as.integer(strsplit(m,".",fixed=TRUE)[[1]]); all(o>=0 & o<=255)},
              base_conf=0.7),
    passport = list(type="passport", identifier="national_id",
               # generic passport: 1-2 letters + 6-8 digits (loose, low confidence)
               pattern="\\b[A-Za-z]{1,2}[0-9]{6,8}\\b",
               validate=NULL, base_conf=0.35),
    mrn = list(type="mrn", identifier="mrn",
               # generic hospital record no: letters + 6-10 digits (tunable)
               pattern="\\b[A-Za-z]{0,3}[0-9]{6,10}\\b",
               validate=NULL, base_conf=0.4),
    creditcard = list(type="account", identifier="other_id",
               pattern="\\b(?:[0-9]{4}[ -]?){3}[0-9]{4}\\b",
               validate=function(m){se_luhn(gsub("[ -]","",m))}, base_conf=0.6)
  )
  if (isTRUE(postal6)) {
    # bare 6-digit run as a possible postal code (ambiguous -> low confidence,
    # placed last so the anchored "Singapore NNNNNN" form wins where both apply).
    # opt-in, so act on it: confidence clears the free-text redaction threshold
    # (0.5) and beats the loose mrn detector (0.4) on the same 6-digit run.
    d$postal6 <- list(type="postal", identifier="postal_code",
                      pattern="\\b[0-9]{6}\\b", validate=NULL, base_conf=0.5)
  }
  d
}

# Luhn check for card-like numbers.
se_luhn <- function(num) {
  d <- as.integer(strsplit(gsub("[^0-9]","",num),"")[[1]])
  if (length(d) < 12) return(FALSE)
  d <- rev(d)
  for (i in seq_along(d)) if (i %% 2 == 0) { d[i] <- d[i]*2; if (d[i] > 9) d[i] <- d[i]-9 }
  sum(d) %% 10 == 0
}

#' Scan a single free-text string, returning a data.frame of spans.
#' cols: start,end,match,type,identifier,detector,confidence
se_scan_text <- function(text, detectors = se_detectors()) {
  out <- list()
  if (is.na(text) || !nzchar(text)) return(.se_empty_spans())
  text <- as.character(text)
  for (nm in names(detectors)) {
    d <- detectors[[nm]]
    m <- gregexpr(d$pattern, text, perl = TRUE, ignore.case = TRUE)[[1]]
    if (m[1] == -1) next
    lens <- attr(m, "match.length")
    for (i in seq_along(m)) {
      s <- m[i]; e <- s + lens[i] - 1L
      mstr <- substr(text, s, e)
      conf <- d$base_conf
      if (!is.null(d$validate)) {
        ok <- tryCatch(isTRUE(d$validate(mstr)), error = function(err) FALSE)
        if (ok) conf <- 0.99 else conf <- max(0.1, conf - 0.4)
      }
      out[[length(out) + 1L]] <- data.frame(
        start=s, end=e, match=mstr, type=d$type, identifier=d$identifier,
        detector=paste0("rule:", nm), confidence=conf, stringsAsFactors=FALSE)
    }
  }
  if (!length(out)) return(.se_empty_spans())
  do.call(rbind, out)
}

#' Drop spans that overlap a kept span, keeping the widest (then highest-
#' confidence) span in each overlap cluster. Expects columns start,end,confidence.
#' Used before applying replacements so an ambiguous bare-6-digit postal span and
#' the anchored "Singapore NNNNNN" span covering it don't both get transformed.
se_dedup_overlaps <- function(sp) {
  if (is.null(sp) || !nrow(sp)) return(sp)
  ord <- order((sp$end - sp$start), sp$confidence, decreasing = TRUE)
  sp <- sp[ord, , drop = FALSE]
  keep <- logical(nrow(sp)); occ <- list()
  for (i in seq_len(nrow(sp))) {
    s <- sp$start[i]; e <- sp$end[i]; ovl <- FALSE
    for (r in occ) if (s <= r[2] && e >= r[1]) { ovl <- TRUE; break }
    if (!ovl) { keep[i] <- TRUE; occ[[length(occ) + 1L]] <- c(s, e) }
  }
  sp[keep, , drop = FALSE]
}

.se_empty_spans <- function() {
  data.frame(start=integer(0), end=integer(0), match=character(0), type=character(0),
             identifier=character(0), detector=character(0), confidence=numeric(0),
             stringsAsFactors=FALSE)
}

#' Classify a single cell value: which identifier types does it look like, and
#' with what confidence (whole-value match, anchored). Used by column profiling.
se_classify_value <- function(value, detectors = se_detectors()) {
  if (is.na(value)) return(character(0))
  v <- trimws(as.character(value))
  if (!nzchar(v)) return(character(0))
  hits <- c()
  for (nm in names(detectors)) {
    d <- detectors[[nm]]
    anchored <- paste0("^(?:", d$pattern, ")$")
    if (grepl(anchored, v, perl = TRUE, ignore.case = TRUE)) {
      conf <- d$base_conf
      if (!is.null(d$validate)) conf <- if (isTRUE(tryCatch(d$validate(v), error=function(e)FALSE))) 0.99 else conf-0.4
      hits[nm] <- conf
    }
  }
  hits
}
