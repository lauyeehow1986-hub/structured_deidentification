# Phase 9 — Feedback-driven detection tuning (auto-improvement) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the detection feedback loop — capture identifiers missed in previous runs, diagnose why, suggest a concrete fix, let a reviewer approve it, apply it (versioned + audited + reversible), and improve future runs — with an optional aggregate-only cross-project register and optional learned-regex generation, both toggleable and default off.

**Architecture:** A new pure-R module `app/R/autotune.R` holds the loop (capture → diagnose → suggest → apply/revert → promote). Raw missed values and the per-project watchlist are AEAD-encrypted and stored **only** in the project folder (reusing `crypto.R` + the project key). Detection is improved by *appending* extra detectors (watchlist + learned patterns) to the shipped set via a new `extra=` hook on `se_detectors()` — shipped detectors are never edited — and by per-identifier confidence floors applied at the gating step. Every behaviour change is an explicit, approved policy delta with a `policy$version` bump and a hash-chained audit event.

**Tech Stack:** R 4.5.x, `sodium` (AEAD secretbox, already used for the crosswalk), `openssl`, `jsonlite`, base R PCRE. No new packages. No network. Air-gapped throughout.

---

## Conventions for this plan (READ FIRST)

These are hard constraints from `CLAUDE.md` and the project's standing rules — they change how every task's "test" steps work:

- **The repo ships NO test framework.** "Tests" here are **scratchpad self-test R scripts** written under the session scratchpad dir, run with `Rscript <file>`, asserting with `stopifnot(...)` and printing `ALL TESTS PASSED`. Never add a `tests/` dir or testthat to the repo. Never `git add` the scratchpad scripts.
- **`Rscript -e` with long multiline code SEGFAULTS on this machine.** Always put test code in a **script file** and run `Rscript path\to\file.R`. Never pass multiline `-e`.
- **Scratchpad dir** (session-specific, no repo pollution): use
  `C:\Users\lauye\AppData\Local\Temp\claude\C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932\8ccd5522-a88b-42ac-8439-bd1a6ff18933\scratchpad`.
  Each test script starts by `setwd()` to the worktree root then `source("app/global.R")`.
- **se_ prefix + snake_case** on every core function. Core stays pure-R and independently testable (no Shiny needed to test it).
- **Never commit real PHI.** All test values are synthetic NRICs (use the checksum-valid `S1234567D`, `S7654321J`; invalid filler like `S0000000X` where a non-match is wanted).
- **Every task ends with a commit.** Commit trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Only stage the repo files the task changed — never `.claude/`, never scratchpad files.
- **Windows line-ending warnings** (`LF will be replaced by CRLF`) on commit are benign — ignore them.

### Test-script skeleton (reuse in every task)

Every scratchpad test file begins with this preamble (adjust the worktree path only if it differs):

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))
# --- test body with stopifnot(...) below ---
```

Run with:

```bash
Rscript "C:/Users/lauye/AppData/Local/Temp/claude/C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932/8ccd5522-a88b-42ac-8439-bd1a6ff18933/scratchpad/tNN_name.R"
```

## Shared data contracts (keep these identical across all tasks)

Locking these now prevents drift between tasks:

- **Feedback record** (one per miss), a plain list:
  `list(ts=<chr ISO>, actor=<chr>, source=<"reviewer"|"gold">, file=<chr>, column=<chr>, row=<int|NA>, start=<int|NA>, end=<int|NA>, value=<chr>, identifier=<chr>, why_missed=<chr|NA>, run_id=<chr|NA>, tuning_id=<chr|NA>)`.
- **`feedback.enc`** decrypts to `list(records = list(<record>, ...))`.
- **`watchlist.enc`** decrypts to `list(pairs = data.frame(identifier=chr, value=chr))` (de-duplicated on `identifier+value`).
- **`se_feedback_read(proj)`** returns a `data.frame` with exactly these columns (0-row df when empty):
  `ts, actor, source, file, column, row, start, end, value, identifier, why_missed, run_id, tuning_id`.
- **`why_missed`** ∈ `{"below_threshold","detector_off","wrong_column","no_pattern","known_value"}`.
- **Suggestion row** (`se_autotune_suggest` returns a `data.frame`):
  `id=chr, identifier=chr, lever=chr, cause=chr, support=int, evidence=chr, delta=chr(JSON), new_detections=int, false_positives=int`.
  `lever` ∈ `{"threshold","watchlist","column_enable","learned_regex"}`.
- **delta JSON** (a policy patch), one of:
  - threshold: `{"lever":"threshold","identifier":"<id>","floor":<num>}`
  - watchlist: `{"lever":"watchlist","pairs":[{"identifier":"<id>","value":"<v>"}, ...]}`
  - column_enable: `{"lever":"column_enable","column":"<col>","detectors":["<id>", ...]}`
  - learned_regex: `{"lever":"learned_regex","identifier":"<id>","pattern":"<pcre>"}`
- **`policy$autotune` defaults:** `list(global_register=FALSE, learned_regex=FALSE, global_register_dir=NULL, min_support=2L, max_fp=0L)`.
- **`policy$applied_tunings`**: named list keyed by `tuning_id`; each entry `list(tuning_id, ts, actor, delta=<parsed list>, prior=<list of pre-apply values for revert>)`.

---

## File Structure

- **Create:** `app/R/autotune.R` — the whole loop (config/paths, capture, diagnose, gold, suggest, generalize, apply/revert, register, detector assembly).
- **Modify:** `app/R/crypto.R` — generic AEAD blob helpers (`se_blob_encrypt`/`se_blob_decrypt`).
- **Modify:** `app/R/detect_r.R` — `extra=` hook on `se_detectors()`; `se_watchlist_detector()`, `se_learned_detectors()`, `.se_pcre_quote()`.
- **Modify:** `app/R/deidentify.R` — per-identifier confidence floors (`policy$conf_overrides`) in the `redact_freetext` gate.
- **Modify:** `app/R/batch.R` — assemble augmented detectors via `se_autotune_detectors(proj)`; promote `force_detectors` columns.
- **Modify:** `app/R/identifiers.R` — add autotune defaults to `se_empty_policy()`.
- **Modify:** `app/global.R` — source `autotune.R`.
- **Modify:** `app/app.R` — "Improvement" nav panel (toggles, gold ingest + recall, suggestions + safety + approve/apply, history + revert, promote) and a miss-capture form.
- **Modify:** `app/batch_cli.R` — `--gold <file>` and `--apply-tunings` flags.
- **Modify:** `docs/roadmap.md`, `docs/packaging.md`, `CLAUDE.md` — document Phase 9.

---

## Task 1: AEAD blob helpers in crypto.R

Generic project-scoped encryption for the feedback store and watchlist, reusing the exact sodium secretbox pattern already proven by the crosswalk.

**Files:**
- Modify: `app/R/crypto.R` (append after `se_crosswalk_decrypt`, around line 173)
- Test: scratchpad `t01_blob.R`

- [ ] **Step 1: Write the failing test**

`t01_blob.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

key <- sodium::random(32L)
obj <- list(records = list(list(value = "S1234567D", identifier = "national_id")))
blob <- se_blob_encrypt(obj, key, "feedback")
# round-trips
stopifnot(identical(se_blob_decrypt(blob, key, "feedback"), obj))
# ciphertext on the wire is not the plaintext value
raw_hex <- paste(as.character(blob$ciphertext), collapse = "")
stopifnot(!grepl("S1234567D", rawToChar(blob$ciphertext), fixed = TRUE))
# wrong label fails to decrypt (label is part of key derivation)
bad <- tryCatch(se_blob_decrypt(blob, key, "watchlist"), error = function(e) "ERR")
stopifnot(identical(bad, "ERR"))
cat("ALL TESTS PASSED\n")
```

- [ ] **Step 2: Run it and confirm it fails**

Run the script. Expected: error `could not find function "se_blob_encrypt"`.

- [ ] **Step 3: Implement**

Append to `app/R/crypto.R`:

```r
# --- generic AEAD blob (feedback store, watchlist) --------------------------
# Same construction as the crosswalk (sodium secretbox, XSalsa20-Poly1305) but
# with a caller-supplied derivation `label`, so different at-rest stores under
# the same project key get independent keys. Used by autotune.R for the
# project-scoped, PHI-bearing feedback.enc / watchlist.enc.
se_blob_encrypt <- function(obj, key, label) {
  k <- se_derive_key(key, label, size = 32L)
  payload <- serialize(obj, connection = NULL)
  nonce <- sodium::random(24L)
  list(nonce = nonce, ciphertext = sodium::data_encrypt(payload, k, nonce))
}

se_blob_decrypt <- function(blob, key, label) {
  k <- se_derive_key(key, label, size = 32L)
  unserialize(sodium::data_decrypt(blob$ciphertext, k, blob$nonce))
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run the script. Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/crypto.R
git commit -m "$(printf 'Autotune: generic AEAD blob helpers for feedback store\n\nse_blob_encrypt/se_blob_decrypt reuse the crosswalk sodium secretbox\npattern with a caller-supplied derivation label, so feedback.enc and\nwatchlist.enc get independent keys under one project key.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 2: Watchlist + learned detectors, and the `extra=` hook

Let approved learned literals/patterns join detection *without editing shipped detectors*.

**Files:**
- Modify: `app/R/detect_r.R` (change `se_detectors` signature line 71; append helpers after `se_luhn`, around line 153)
- Test: scratchpad `t02_extra.R`

- [ ] **Step 1: Write the failing test**

`t02_extra.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

# PCRE-quote escapes regex metacharacters literally
stopifnot(identical(.se_pcre_quote("a.b(c)"), "\\Qa.b(c)\\E"))

# watchlist detector: exact literals -> a detector spec list
wl <- se_watchlist_detector(data.frame(
  identifier = c("mrn", "mrn"), value = c("ABC-99", "ZZ.7"),
  stringsAsFactors = FALSE))
stopifnot(is.list(wl), length(wl) >= 1L)
sp <- se_scan_text("patient ABC-99 seen", se_detectors(extra = wl))
stopifnot(any(sp$match == "ABC-99"))

# a shipped detector still works and shipped set is unchanged when extra=list()
base_names <- names(se_detectors())
stopifnot(identical(names(se_detectors(extra = list())), base_names))
stopifnot(nrow(se_scan_text("S1234567D", se_detectors())) >= 1L)

# learned detector: generalized pattern
ld <- se_learned_detectors(list(list(identifier = "national_id",
                                     pattern = "\\b[XY][0-9]{7}[A-Z]\\b")))
sp2 <- se_scan_text("id X1234567A here", se_detectors(extra = ld))
stopifnot(any(sp2$match == "X1234567A"))
cat("ALL TESTS PASSED\n")
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: `could not find function ".se_pcre_quote"`.

- [ ] **Step 3: Implement**

In `app/R/detect_r.R`, change the signature (line 71) from:

```r
se_detectors <- function(postal6 = getOption("se.detect_postal6", FALSE)) {
```

to:

```r
se_detectors <- function(postal6 = getOption("se.detect_postal6", FALSE),
                         extra = list()) {
```

Then, just before the final `d` return (i.e. after the `if (isTRUE(postal6)) {...}` block, before the closing `d`), insert:

```r
  # Project-specific learned detectors (watchlist literals + learned patterns),
  # appended AFTER the shipped set so shipped behaviour is byte-for-byte
  # reproducible. Assembled by se_autotune_detectors(); empty by default.
  if (length(extra)) d <- c(d, extra)
```

Append after `se_luhn` (after line 153):

```r
# PCRE-quote a literal so regex metacharacters match literally. \Q...\E is the
# PCRE literal span; guard the rare case of a literal "\E" inside the value.
.se_pcre_quote <- function(s) {
  s <- gsub("\\\\E", "\\\\E\\\\\\\\E\\\\Q", s)  # split any embedded \E
  paste0("\\Q", s, "\\E")
}

#' Build exact-match detectors from reviewer-confirmed literals.
#' @param pairs data.frame(identifier, value) — or a list of {identifier,value}
#'   (as it comes back after a project.json round-trip). Groups values per
#'   identifier into one alternation detector each. High base_conf (known hits).
se_watchlist_detector <- function(pairs) {
  if (is.null(pairs)) return(list())
  if (!is.data.frame(pairs)) {                     # coerce list -> data.frame
    if (!length(pairs)) return(list())
    pairs <- do.call(rbind, lapply(pairs, function(p) data.frame(
      identifier = p$identifier, value = p$value, stringsAsFactors = FALSE)))
  }
  if (!nrow(pairs)) return(list())
  out <- list()
  for (id in unique(pairs$identifier)) {
    vals <- unique(pairs$value[pairs$identifier == id])
    vals <- vals[nzchar(vals)]
    if (!length(vals)) next
    pat <- paste0("(?:", paste(vapply(vals, .se_pcre_quote, character(1)),
                               collapse = "|"), ")")
    out[[paste0("wl_", id)]] <- list(
      type = id, identifier = id, pattern = pat, validate = NULL,
      base_conf = 0.95)
  }
  out
}

#' Build detectors from approved learned regex patterns.
#' @param learned list of list(identifier, pattern, ...).
se_learned_detectors <- function(learned) {
  if (is.null(learned) || !length(learned)) return(list())
  out <- list()
  for (i in seq_along(learned)) {
    e <- learned[[i]]
    if (is.null(e$pattern) || !nzchar(e$pattern)) next
    id <- e$identifier %||% "other_id"
    out[[paste0("learned_", i)]] <- list(
      type = id, identifier = id, pattern = e$pattern, validate = NULL,
      base_conf = e$base_conf %||% 0.9)
  }
  out
}
```

> Note: `%||%` is defined in `project.R` and loaded before use at runtime; it is available in `detect_r.R` at call time because `se_detectors`/these helpers are only *invoked* after `global.R` has sourced everything.

- [ ] **Step 4: Run it and confirm it passes**

Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/detect_r.R
git commit -m "$(printf 'Autotune: extra= detector hook + watchlist/learned detectors\n\nse_detectors(extra=) appends project-specific detectors after the\nshipped set (never edits it). se_watchlist_detector builds \\\\Q..\\\\E\nexact-match detectors from reviewer-confirmed literals; se_learned_\ndetectors builds detectors from approved generalized patterns.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 3: Per-identifier confidence floors in the redact gate

Let an approved threshold lever lower the redaction floor for one identifier without touching the global `min_conf`.

**Files:**
- Modify: `app/R/deidentify.R` (the `redact_freetext` branch gating, lines 282-284)
- Test: scratchpad `t03_conf.R`

- [ ] **Step 1: Write the failing test**

`t03_conf.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

# A loose passport-shaped token scores 0.35 (below the 0.5 default floor) and is
# NOT redacted by default; a conf_override for national_id lowers the floor so it
# IS redacted.
df  <- data.frame(note = c("ref AB123456 xx"), stringsAsFactors = FALSE)
key <- sodium::random(32L)

pol_base <- list(columns = list(note = list(action = "redact_freetext")),
                 freetext_opts = list(min_conf = 0.5, use_pf = FALSE))
r1 <- se_deidentify_table(df, pol_base, key)
stopifnot(grepl("AB123456", r1$data$note))   # not redacted at 0.5

pol_ovr <- pol_base
pol_ovr$conf_overrides <- list(national_id = 0.3)
r2 <- se_deidentify_table(df, pol_ovr, key)
stopifnot(!grepl("AB123456", r2$data$note))  # redacted once floor drops to 0.3
cat("ALL TESTS PASSED\n")
```

> `se_deidentify_table` returns `list(data=, crosswalk=, summary=)` (verified at `deidentify.R:326`) — the output frame is `$data`.

- [ ] **Step 2: Run it and confirm it fails**

Expected: the second assertion fails (`AB123456` still present) because `conf_overrides` is not yet honoured.

- [ ] **Step 3: Implement**

In `app/R/deidentify.R`, inside the `redact_freetext` branch, replace the single gating line (currently line 282):

```r
            sp <- sp[sp$confidence >= min_conf, , drop = FALSE]
```

with a per-identifier floor:

```r
            # Per-identifier confidence floor (reviewer-approved threshold
            # lever). Falls back to the global min_conf when no override set.
            ov  <- policy$conf_overrides %||% list()
            thr <- rep(min_conf, nrow(sp))
            if (length(ov)) {
              hit <- sp$identifier %in% names(ov)
              if (any(hit)) thr[hit] <- unlist(ov[sp$identifier[hit]],
                                               use.names = FALSE)
            }
            sp <- sp[sp$confidence >= thr, , drop = FALSE]
```

- [ ] **Step 4: Run it and confirm it passes**

Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/deidentify.R
git commit -m "$(printf 'Autotune: per-identifier confidence floors in redact gate\n\npolicy$conf_overrides lowers the free-text redaction floor for a\nspecific identifier without moving the global min_conf, so a below-\nthreshold miss can be caught after reviewer approval.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 4: autotune.R skeleton — config, paths, feedback capture (encrypted)

Create the module and the PHI-bearing, project-scoped, encrypted capture store.

**Files:**
- Create: `app/R/autotune.R`
- Modify: `app/R/identifiers.R` (`se_empty_policy` defaults)
- Modify: `app/global.R` (source order)
- Test: scratchpad `t04_capture.R`

- [ ] **Step 1: Write the failing test**

`t04_capture.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

tmp <- file.path(tempdir(), paste0("at_", as.integer(runif(1, 1, 1e6))))
unlink(tmp, recursive = TRUE)
proj <- se_project_create(tmp, "autotune-cap", actor = "d", hash_scope = "project")

# defaults present + toggles OFF
cfg <- se_autotune_config(proj)
stopifnot(isFALSE(cfg$global_register), isFALSE(cfg$learned_regex),
          cfg$min_support == 2L, cfg$max_fp == 0L)

# record two misses
se_feedback_record_miss(proj, file = "s.csv", column = "note", row = 1L,
  span = c(5L, 13L), value = "S1234567D", identifier = "national_id",
  source = "reviewer", actor = "r")
se_feedback_record_miss(proj, file = "s.csv", column = "serial", row = 2L,
  span = NULL, value = "S7654321J", identifier = "national_id",
  source = "reviewer", actor = "r")

fb <- se_feedback_read(proj)
stopifnot(nrow(fb) == 2L,
          all(c("ts","actor","source","file","column","row","start","end",
                "value","identifier","why_missed","run_id","tuning_id")
              %in% names(fb)),
          all(fb$identifier == "national_id"))

# PHI boundary: ciphertext on disk does not contain the raw value.
# NOTE: do NOT use rawToChar on ciphertext — embedded nul bytes crash it. Search
# the raw byte stream for the plaintext's byte sequence instead.
.contains_bytes <- function(hay, needle) {
  n <- length(needle); if (!n) return(TRUE)
  h <- length(hay);    if (h < n) return(FALSE)
  for (i in seq_len(h - n + 1L))
    if (identical(hay[i:(i + n - 1L)], needle)) return(TRUE)
  FALSE
}
paths <- se_autotune_paths(tmp)
stopifnot(file.exists(paths$feedback))
raw_fb <- readBin(paths$feedback, "raw", n = file.info(paths$feedback)$size)
stopifnot(!.contains_bytes(raw_fb, charToRaw("S1234567D")))

# audit event recorded
p <- se_project_paths(tmp)
au <- se_audit_read(p$audit)
stopifnot(any(vapply(au, function(e) identical(e$action, "feedback_miss_marked"),
                     logical(1))))
cat("ALL TESTS PASSED\n")
```

> `se_audit_read` returns a list of entries; confirm the element name is `$action` by reading `hashchain.R:71-` before finalizing.

- [ ] **Step 2: Run it and confirm it fails**

Expected: `could not find function "se_autotune_config"`.

- [ ] **Step 3a: Add policy defaults** in `app/R/identifiers.R`, change `se_empty_policy` (lines 77-79) to:

```r
se_empty_policy <- function() {
  list(columns = list(), freetext_columns = character(0),
       conf_overrides = list(), learned_patterns = list(),
       applied_tunings = list(), version = 1L,
       autotune = list(global_register = FALSE, learned_regex = FALSE,
                       global_register_dir = NULL, min_support = 2L,
                       max_fp = 0L))
}
```

- [ ] **Step 3b: Create `app/R/autotune.R`** with the config/paths/capture core:

```r
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
#' Defined here (not with apply/) because gold ingest in Task 6 needs it.
se_autotune_detectors <- function(proj, postal6 = getOption("se.detect_postal6",
                                                            FALSE)) {
  wl <- tryCatch(.se_watchlist_load(proj)$pairs, error = function(e) NULL)
  extra <- c(se_watchlist_detector(wl),
             se_learned_detectors(proj$policy$learned_patterns %||% list()))
  se_detectors(postal6 = postal6, extra = extra)
}
```

- [ ] **Step 3c: Wire into `app/global.R`** — add `"autotune.R"` to the `files` vector (after `"batch.R"`), line 14:

```r
             "sdc_transforms.R", "report.R", "engine_py.R", "batch.R",
             "autotune.R")
```

- [ ] **Step 4: Run it and confirm it passes**

Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/autotune.R app/R/identifiers.R app/global.R
git commit -m "$(printf 'Autotune: module skeleton + encrypted feedback capture\n\nse_autotune_config/paths, project-scoped AEAD-encrypted feedback store,\nse_feedback_record_miss (audited) + se_feedback_read. PHI stays in the\nproject folder, encrypted under the project key. Policy gains autotune\ndefaults (both toggles off). global.R sources autotune.R.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 5: Diagnose — classify why each miss happened

**Files:**
- Modify: `app/R/autotune.R` (append)
- Test: scratchpad `t05_diagnose.R`

- [ ] **Step 1: Write the failing test**

`t05_diagnose.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

tmp <- file.path(tempdir(), paste0("at5_", as.integer(runif(1, 1, 1e6))))
unlink(tmp, recursive = TRUE)
proj <- se_project_create(tmp, "diag", actor = "d")

# below_threshold: passport-shaped, matches a detector at 0.35 (< 0.5 floor)
se_feedback_record_miss(proj, "s.csv", "note", 1L, NULL, "AB123456",
                        "national_id", "reviewer", "r")
# no_pattern: nothing matches this shape
se_feedback_record_miss(proj, "s.csv", "note", 2L, NULL, "ward-7G-bed12",
                        "location", "reviewer", "r")
# known_value: the SAME literal recurs (>= min_support)
se_feedback_record_miss(proj, "s.csv", "acc", 3L, NULL, "REC-XYZ",
                        "mrn", "reviewer", "r")
se_feedback_record_miss(proj, "s.csv", "acc", 4L, NULL, "REC-XYZ",
                        "mrn", "reviewer", "r")

dg <- se_autotune_diagnose(proj)
by_row <- setNames(dg$why_missed, dg$row)
stopifnot(by_row[["1"]] == "below_threshold",
          by_row[["2"]] == "no_pattern",
          by_row[["3"]] == "known_value",
          by_row[["4"]] == "known_value")
cat("ALL TESTS PASSED\n")
```

- [ ] **Step 2: Run it and confirm it fails** — `could not find function "se_autotune_diagnose"`.

- [ ] **Step 3: Implement** — append to `app/R/autotune.R`:

```r
# --- diagnose ---------------------------------------------------------------
#' Classify each miss into why_missed, deterministically. Reuses the shipped
#' detectors via se_classify_value. min_conf floor defaults to 0.5 (the free-text
#' redaction default) unless a conf_override is set for that identifier.
se_autotune_diagnose <- function(proj, min_conf = 0.5) {
  fb <- se_feedback_read(proj)
  if (!nrow(fb)) return(fb)
  ov     <- proj$policy$conf_overrides %||% list()
  minsup <- se_autotune_config(proj)$min_support
  # recurring exact literals (case-insensitive) at or above min_support
  vlow   <- tolower(fb$value)
  counts <- table(vlow)
  for (i in seq_len(nrow(fb))) {
    val <- fb$value[i]; id <- fb$identifier[i]
    floor_i <- ov[[id]] %||% min_conf
    hits <- se_classify_value(val)              # named numeric: detector -> conf
    id_hit <- NA_real_
    if (length(hits)) {
      # best confidence among detectors whose identifier matches this miss
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
```

> Rationale for ordering: a detector match at/above the floor that was still missed means the column wasn't scanned (`wrong_column`); below the floor means `below_threshold`; a recurring exact literal with no same-identifier match is a `known_value`; a match under a *different* identifier is `detector_off`; nothing at all is `no_pattern`.

- [ ] **Step 4: Run it and confirm it passes** — `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/autotune.R
git commit -m "$(printf 'Autotune: diagnose why each identifier was missed\n\nse_autotune_diagnose classifies each miss (below_threshold / wrong_\ncolumn / detector_off / known_value / no_pattern) deterministically by\nre-running the shipped detectors via se_classify_value and comparing to\nthe active per-identifier floor and min_support.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 6: Ground-truth ingest — recall + record gold misses

**Files:**
- Modify: `app/R/autotune.R` (append)
- Test: scratchpad `t06_gold.R`

- [ ] **Step 1: Write the failing test**

`t06_gold.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

tmp <- file.path(tempdir(), paste0("at6_", as.integer(runif(1, 1, 1e6))))
unlink(tmp, recursive = TRUE)
proj <- se_project_create(tmp, "gold", actor = "d")

din <- file.path(tmp, "in"); dir.create(din)
write.csv(data.frame(note = c("call S1234567D", "misc row two"),
                     stringsAsFactors = FALSE),
          file.path(din, "s.csv"), row.names = FALSE)

# gold says both an NRIC (detectable) and a bare surname (not detectable) exist
gold <- data.frame(
  file = c("s.csv", "s.csv"),
  column = c("note", "note"),
  value = c("S1234567D", "Tanaka"),
  identifier = c("national_id", "name"),
  stringsAsFactors = FALSE)

res <- se_autotune_ingest_gold(proj, gold,
         inputs = se_batch_plan(din), actor = "r")

# recall: national_id caught (1/1), name missed (0/1)
rc <- setNames(res$recall$recall, res$recall$identifier)
stopifnot(rc[["national_id"]] == 1, rc[["name"]] == 0)

# the missed gold item was recorded as a source="gold" miss
fb <- se_feedback_read(proj)
stopifnot(any(fb$source == "gold" & fb$value == "Tanaka"))

p <- se_project_paths(tmp)
au <- se_audit_read(p$audit)
stopifnot(any(vapply(au, function(e)
  identical(e$action, "feedback_gold_ingested"), logical(1))))
cat("ALL TESTS PASSED\n")
```

> Verified: `se_batch_plan()` returns a data.frame with columns `path, file, type` (`batch.R:33`); `type=="table"` covers csv/xlsx. The ingest reads csv table inputs to compute what detection would catch.

- [ ] **Step 2: Run it and confirm it fails** — `could not find function "se_autotune_ingest_gold"`.

- [ ] **Step 3: Implement** — append to `app/R/autotune.R`:

```r
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
```

- [ ] **Step 4: Run it and confirm it passes** — `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/autotune.R
git commit -m "$(printf 'Autotune: ground-truth ingest with per-identifier recall\n\nse_autotune_ingest_gold re-detects the inputs, diffs against a gold\ntable, records uncovered items as source=gold misses, and returns\nper-identifier recall. Audited as feedback_gold_ingested.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 7: Suggest (ranked, safety preview) + regex generalizer

**Files:**
- Modify: `app/R/autotune.R` (append)
- Test: scratchpad `t07_suggest.R`

- [ ] **Step 1: Write the failing test**

`t07_suggest.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

# generalizer: three temp-IC-like values -> a bounded pattern that covers them
g <- se_autotune_generalize(c("X1234567A","Y7654321B","X0001112C"))
stopifnot(!is.null(g), g$coverage == 1, grepl("\\[", g$pattern))
# over-broad guard: a pattern that would match most of a big corpus is rejected
corpus <- as.character(1:200)
gb <- se_autotune_generalize(c("12","34"), corpus = corpus, max_fp = 0)
stopifnot(is.null(gb))

tmp <- file.path(tempdir(), paste0("at7_", as.integer(runif(1, 1, 1e6))))
unlink(tmp, recursive = TRUE)
proj <- se_project_create(tmp, "sug", actor = "d")
# turn learned-regex ON for this project so no_pattern yields a regex suggestion
proj$policy$autotune$learned_regex <- TRUE

# two recurring known values (known_value -> watchlist), min_support=2 default
se_feedback_record_miss(proj, "s.csv", "acc", 1L, NULL, "REC-XYZ", "mrn", "reviewer","r")
se_feedback_record_miss(proj, "s.csv", "acc", 2L, NULL, "REC-XYZ", "mrn", "reviewer","r")
# one below_threshold (passport-shaped) -> threshold lever
se_feedback_record_miss(proj, "s.csv", "note", 3L, NULL, "AB123456", "national_id","reviewer","r")

sg <- se_autotune_suggest(proj)
stopifnot(nrow(sg) >= 1L,
          all(c("id","identifier","lever","cause","support","evidence","delta",
                "new_detections","false_positives") %in% names(sg)),
          "watchlist" %in% sg$lever,     # REC-XYZ recurs >= min_support
          "threshold" %in% sg$lever)     # AB123456 below floor
# each delta parses as JSON
invisible(lapply(sg$delta, jsonlite::fromJSON))
cat("ALL TESTS PASSED\n")
```

- [ ] **Step 2: Run it and confirm it fails** — `could not find function "se_autotune_generalize"`.

- [ ] **Step 3: Implement** — append to `app/R/autotune.R`:

```r
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
      # crude FP signal: the same span already matched a different identifier
      for (j in seq_len(nrow(gained))) {
        ov <- b[b$start <= gained$end[j] & b$end >= gained$start[j], , drop=FALSE]
        if (nrow(ov)) n_fp <- n_fp + 1L
      }
    }
  }
  list(new_detections = as.integer(n_new), false_positives = as.integer(n_fp))
}
```

- [ ] **Step 4: Run it and confirm it passes** — `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/autotune.R
git commit -m "$(printf 'Autotune: ranked suggestions + safety preview + regex generalizer\n\nse_autotune_suggest aggregates diagnosed misses per identifier x cause\n(>= min_support), maps cause -> lever, emits a JSON policy-patch delta\nand a safety preview (new detections / FP). se_autotune_generalize\nabstracts literals to a bounded PCRE with a specificity guard, capped at\nmax_fp, only when learned_regex is on; falls back to watchlist otherwise.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 8: Apply / revert + augmented detector assembly + force_detectors

The behaviour-changing task: approved deltas merge into policy (versioned, audited, reversible); detection assembles the augmented set; `force_detectors` columns get scanned.

**Files:**
- Modify: `app/R/autotune.R` (append `se_autotune_detectors`, `se_autotune_apply`, `se_autotune_revert`)
- Modify: `app/R/batch.R` (assemble augmented detectors; promote `force_detectors` columns)
- Test: scratchpad `t08_apply.R`

- [ ] **Step 1: Write the failing test**

`t08_apply.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

tmp <- file.path(tempdir(), paste0("at8_", as.integer(runif(1, 1, 1e6))))
unlink(tmp, recursive = TRUE)
proj <- se_project_create(tmp, "apply", actor = "d")
proj$policy$columns <- list(note = list(action = "redact_freetext"))
proj$policy$freetext_opts <- list(min_conf = 0.5, use_pf = FALSE)
se_project_save(proj)

din <- file.path(tmp, "in"); dir.create(din)
write.csv(data.frame(note = c("code REC-XYZ present"), stringsAsFactors = FALSE),
          file.path(din, "s.csv"), row.names = FALSE)

# baseline: REC-XYZ (a watchlist-worthy literal) is NOT caught
r0 <- se_batch_run(proj, se_batch_plan(din), opts = list(actor = "v"))
out0 <- readLines(file.path(se_project_paths(tmp)$outputs, "s.deid.csv"))
stopifnot(any(grepl("REC-XYZ", out0)))

# capture two misses -> suggest -> approve the watchlist suggestion -> apply
se_feedback_record_miss(proj,"s.csv","note",1L,NULL,"REC-XYZ","mrn","reviewer","r")
se_feedback_record_miss(proj,"s.csv","note",1L,NULL,"REC-XYZ","mrn","reviewer","r")
sg <- se_autotune_suggest(proj)
appr <- sg[sg$lever == "watchlist", , drop = FALSE][1, , drop = FALSE]
v_before <- proj$policy$version
proj <- se_autotune_apply(proj, appr, actor = "r")
stopifnot(proj$policy$version == v_before + 1L,
          length(proj$policy$applied_tunings) == 1L)

# re-run: REC-XYZ now redacted
r1 <- se_batch_run(proj, se_batch_plan(din), opts = list(actor = "v", force = TRUE))
out1 <- readLines(file.path(se_project_paths(tmp)$outputs, "s.deid.csv"))
stopifnot(!any(grepl("REC-XYZ", out1)))

# audit chain verifies and the apply event is present
p <- se_project_paths(tmp)
stopifnot(isTRUE(se_audit_verify(p$audit)$ok))
au <- se_audit_read(p$audit)
stopifnot(any(vapply(au, function(e) identical(e$action,"feedback_tuning_applied"),
                     logical(1))))

# revert restores prior behaviour
tid <- names(proj$policy$applied_tunings)[1]
proj <- se_autotune_revert(proj, tid, actor = "r")
r2 <- se_batch_run(proj, se_batch_plan(din), opts = list(actor="v", force=TRUE))
out2 <- readLines(file.path(se_project_paths(tmp)$outputs, "s.deid.csv"))
stopifnot(any(grepl("REC-XYZ", out2)))
cat("ALL TESTS PASSED\n")
```

> Verified: table output is `<base>.deid.csv` (`batch.R:41`) and `opts$force` re-runs an already-output file (`batch.R:78,93`).

- [ ] **Step 2: Run it and confirm it fails** — `could not find function "se_autotune_detectors"`.

- [ ] **Step 3a: Implement in `app/R/autotune.R`** (append). `se_autotune_detectors` was already added in Task 4 — do **not** redefine it here; this task only adds apply/revert:

```r
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
```

- [ ] **Step 3b: Wire batch.R** — in `app/R/batch.R`, replace the detector assembly (line 76 `detectors  <- se_detectors()`) with:

```r
  detectors  <- se_autotune_detectors(proj)
  # Promote columns carrying reviewer-approved force_detectors to be scanned for
  # free-text PII even if their action was "keep" (the misplaced-PII fix).
  if (length(policy$columns)) {
    for (cn in names(policy$columns)) {
      spc <- policy$columns[[cn]]
      if (length(spc$force_detectors) &&
          (is.null(spc$action) || identical(spc$action, "keep"))) {
        spc$action <- "redact_freetext"
        policy$columns[[cn]] <- spc
      }
    }
    if (is.null(policy$freetext_opts))
      policy$freetext_opts <- list(min_conf = 0.5, use_pf = FALSE)
  }
```

> Verified: `se_deidentify_file` (`checkpoint.R:206`) already takes `detectors = se_detectors()` and forwards it to `se_deidentify_table`; `batch.R:104` already passes `detectors = detectors`. So changing line 76 to `se_autotune_detectors(proj)` is sufficient — the augmented set (plain lists) serializes fine to parallel workers. No signature change needed anywhere else.

- [ ] **Step 4: Run it and confirm it passes** — `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/autotune.R app/R/batch.R
git commit -m "$(printf 'Autotune: apply/revert (versioned+audited) + augmented detection\n\nse_autotune_apply merges approved deltas into policy (conf_overrides,\nwatchlist, force_detectors, learned_patterns), bumps policy$version,\nsnapshots prior state for revert, and audits feedback_tuning_applied.\nse_autotune_revert restores the snapshot. Batch assembles detectors via\nse_autotune_detectors and promotes force_detectors columns to scan.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 9: Global register (aggregate-only, toggleable, PHI-asserting)

**Files:**
- Modify: `app/R/autotune.R` (append)
- Test: scratchpad `t09_register.R`

- [ ] **Step 1: Write the failing test**

`t09_register.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

tmp <- file.path(tempdir(), paste0("at9_", as.integer(runif(1, 1, 1e6))))
unlink(tmp, recursive = TRUE)
proj <- se_project_create(tmp, "reg", actor = "d")
reg  <- file.path(tempdir(), paste0("reg_", as.integer(runif(1, 1, 1e6))))

# toggle OFF -> promote is a no-op (no register written)
se_feedback_record_miss(proj,"s.csv","note",1L,NULL,"S1234567D","national_id","reviewer","r")
se_feedback_record_miss(proj,"s.csv","note",2L,NULL,"S7654321J","national_id","reviewer","r")
sg <- se_autotune_suggest(proj)
proj <- se_autotune_apply(proj, sg[sg$lever == "watchlist", ][1, ], actor = "r")
out_off <- se_register_promote(proj, sg, register_dir = reg, actor = "r")
stopifnot(is.null(out_off) || isFALSE(out_off$written))
stopifnot(!file.exists(file.path(reg, "register.json")))

# toggle ON -> aggregate entry written, NO literal PHI in the file
proj$policy$autotune$global_register <- TRUE
proj$policy$autotune$global_register_dir <- reg
se_register_promote(proj, sg, register_dir = reg, actor = "r")
rj <- file.path(reg, "register.json")
stopifnot(file.exists(rj))
disk <- paste(readLines(rj), collapse = "\n")
stopifnot(!grepl("S1234567D", disk, fixed = TRUE),
          !grepl("S7654321J", disk, fixed = TRUE),
          grepl("national_id", disk))

p <- se_project_paths(tmp)
au <- se_audit_read(p$audit)
stopifnot(any(vapply(au, function(e) identical(e$action,"register_promoted"),
                     logical(1))))
cat("ALL TESTS PASSED\n")
```

- [ ] **Step 2: Run it and confirm it fails** — `could not find function "se_register_promote"`.

- [ ] **Step 3: Implement** — append to `app/R/autotune.R`:

```r
# --- global register (aggregate-only; toggleable) ---------------------------
#' Promote aggregate-only priors to a cross-project register. No-op unless the
#' project's global_register toggle is on. Asserts no literal value is written.
se_register_promote <- function(proj, applied, register_dir = NULL,
                                actor = "unknown") {
  cfg <- se_autotune_config(proj)
  if (!isTRUE(cfg$global_register)) return(list(written = FALSE))
  register_dir <- register_dir %||% cfg$global_register_dir
  if (is.null(register_dir) || !nzchar(register_dir))
    stop("global_register on but no register_dir")
  dir.create(register_dir, showWarnings = FALSE, recursive = TRUE)
  rj <- file.path(register_dir, "register.json")
  reg <- if (file.exists(rj)) jsonlite::fromJSON(rj, simplifyVector = FALSE)
         else list(entries = list())

  dg <- se_autotune_diagnose(proj)
  # aggregate per identifier: counts + threshold reco + generalized patterns.
  # NEVER a literal value or a watchlist pair.
  for (id in unique(dg$identifier)) {
    sub <- dg[dg$identifier == id, , drop = FALSE]
    pats <- character(0)
    lp <- proj$policy$learned_patterns %||% list()
    for (e in lp) if (identical(e$identifier, id)) pats <- c(pats, e$pattern)
    thr <- proj$policy$conf_overrides[[id]] %||% NA_real_
    entry <- list(identifier = id, miss_count = nrow(sub),
                  projects = list(proj$name),
                  threshold_reco = thr, patterns = as.list(unique(pats)),
                  updated_ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
    reg$entries[[length(reg$entries) + 1L]] <- entry
  }
  # HARD PHI ASSERTION: the serialized register must not contain any raw value.
  wl <- .se_watchlist_load(proj)$pairs
  ser <- jsonlite::toJSON(reg, auto_unbox = TRUE)
  if (nrow(wl)) for (v in wl$value)
    if (nzchar(v) && grepl(v, ser, fixed = TRUE))
      stop("refusing to promote: literal value would leak to global register")
  jsonlite::write_json(reg, rj, auto_unbox = TRUE, pretty = TRUE)
  se_audit_append(se_project_paths(proj$dir)$audit, "register_promoted", actor,
                  list(register_dir = register_dir,
                       identifiers = unique(dg$identifier)))
  list(written = TRUE, path = rj)
}

#' Surface cross-project priors (aggregate) as suggestions for a new project.
se_register_suggest <- function(register_dir, identifiers = NULL) {
  rj <- file.path(register_dir, "register.json")
  if (!file.exists(rj)) return(list())
  reg <- jsonlite::fromJSON(rj, simplifyVector = FALSE)
  ent <- reg$entries %||% list()
  if (!is.null(identifiers))
    ent <- Filter(function(e) e$identifier %in% identifiers, ent)
  ent
}
```

- [ ] **Step 4: Run it and confirm it passes** — `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/R/autotune.R
git commit -m "$(printf 'Autotune: aggregate-only cross-project global register\n\nse_register_promote writes per-identifier counts, threshold recos and\ngeneralized patterns to a shared register.json only when the toggle is\non, and refuses if any watchlist literal would leak. se_register_suggest\nsurfaces those priors. Audited as register_promoted.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 10: Consolidated PHI-boundary + toggle self-test

A dedicated guard test (spec test items 6 & 7) that survives as a documented, re-runnable check.

**Files:**
- Test only: scratchpad `t10_phi_toggles.R` (no repo change unless a gap is found)

- [ ] **Step 1: Write the test**

`t10_phi_toggles.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

tmp <- file.path(tempdir(), paste0("at10_", as.integer(runif(1, 1, 1e6))))
unlink(tmp, recursive = TRUE)
proj <- se_project_create(tmp, "phi", actor = "d")
reg  <- file.path(tempdir(), paste0("reg10_", as.integer(runif(1, 1, 1e6))))

se_feedback_record_miss(proj,"s.csv","note",1L,NULL,"S1234567D","national_id","reviewer","r")
se_feedback_record_miss(proj,"s.csv","note",2L,NULL,"S1234567D","national_id","reviewer","r")

# feedback + watchlist ciphertext on disk != plaintext (nul-safe byte search;
# rawToChar crashes on embedded nul bytes in ciphertext)
.contains_bytes <- function(hay, needle) {
  n <- length(needle); if (!n) return(TRUE)
  h <- length(hay);    if (h < n) return(FALSE)
  for (i in seq_len(h - n + 1L))
    if (identical(hay[i:(i + n - 1L)], needle)) return(TRUE)
  FALSE
}
sg <- se_autotune_suggest(proj)
proj <- se_autotune_apply(proj, sg[sg$lever=="watchlist", ][1, ], actor="r")
pa <- se_autotune_paths(tmp)
for (f in c(pa$feedback, pa$watchlist)) {
  raw <- readBin(f, "raw", n = file.info(f)$size)
  stopifnot(!.contains_bytes(raw, charToRaw("S1234567D")))
}

# learned-regex OFF (default) => generalizer never yields a learned_regex lever
proj2 <- se_project_create(file.path(tempdir(),
           paste0("at10b_", as.integer(runif(1,1,1e6)))), "noreg", actor="d")
se_feedback_record_miss(proj2,"s.csv","c",1L,NULL,"ward-7G-bed12","location","reviewer","r")
se_feedback_record_miss(proj2,"s.csv","c",2L,NULL,"ward-8H-bed99","location","reviewer","r")
sg2 <- se_autotune_suggest(proj2)
stopifnot(!("learned_regex" %in% sg2$lever))

# global register OFF (default) => promote writes nothing
stopifnot(isFALSE(se_register_promote(proj2, sg2, register_dir = reg,
                                      actor = "r")$written %||% FALSE))
cat("ALL TESTS PASSED\n")
```

- [ ] **Step 2: Run it** — Expected: `ALL TESTS PASSED`. If any assertion fails, fix the offending module from Tasks 4/7/8/9 (do not weaken the test), re-run, then include that module in the commit.

- [ ] **Step 3: Commit** (only if a source fix was needed; otherwise skip the commit — the scratchpad file is never committed)

```bash
git add app/R/autotune.R
git commit -m "$(printf 'Autotune: harden PHI boundary / toggle guarantees\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 11: CLI — `--gold` and `--apply-tunings`

**Files:**
- Modify: `app/batch_cli.R`
- Test: scratchpad `t11_cli.R` (invokes the CLI as a subprocess)

- [ ] **Step 1: Read the current CLI arg parsing**

Read `app/batch_cli.R` in full first to reuse its existing `getflag`/`getopt` helpers and the point where it builds `opts` and calls `se_batch_run`. The additions must slot into that structure, not replace it.

- [ ] **Step 2: Write the failing test**

`t11_cli.R`:

```r
root <- "C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932"
rscript <- file.path(R.home("bin"), "Rscript.exe")
tmp <- file.path(tempdir(), paste0("cli_", as.integer(runif(1,1,1e6))))
dir.create(tmp, recursive = TRUE)
proj <- file.path(tmp, "proj"); din <- file.path(tmp, "in"); dir.create(din)
write.csv(data.frame(note = c("call S1234567D", "misc")), file.path(din, "s.csv"),
          row.names = FALSE)
gold <- file.path(tmp, "gold.csv")
write.csv(data.frame(file="s.csv", column="note", value="Tanaka",
                     identifier="name"), gold, row.names = FALSE)

# create the project via a tiny bootstrap so the CLI has something to open
setwd(root); suppressWarnings(suppressMessages(source("app/global.R")))
se_project_create(proj, "cli", actor = "d")

args <- c(file.path(root, "app/batch_cli.R"),
          "--project", proj, "--inputs", din, "--actor", "v", "--gold", gold)
out <- system2(rscript, shQuote(args), stdout = TRUE, stderr = TRUE)
cat(out, sep = "\n")
# gold miss recorded => summary or feedback store reflects the missed name
proj_o <- se_project_open(proj)
fb <- se_feedback_read(proj_o)
stopifnot(any(fb$source == "gold" & fb$value == "Tanaka"))
cat("ALL TESTS PASSED\n")
```

- [ ] **Step 3: Implement** — in `app/batch_cli.R`, after the existing `se_batch_run(...)` call and summary write, add (adapting variable names to the file's actual ones):

```r
# --- Phase 9: optional ground-truth ingest + headless apply -----------------
gold_path <- getopt("--gold", NA_character_)
if (!is.na(gold_path) && nzchar(gold_path) && file.exists(gold_path)) {
  gold <- utils::read.csv(gold_path, stringsAsFactors = FALSE,
                          colClasses = "character")
  proj <- se_project_open(project_dir)          # reopen to pick up run state
  ing  <- se_autotune_ingest_gold(proj, gold, inputs = plan,
                                  actor = actor)
  sug  <- se_autotune_suggest(proj)
  # write suggestions into the batch summary for the reviewer
  sfile <- file.path(project_dir, "batch_summary.json")
  summ <- if (file.exists(sfile)) jsonlite::fromJSON(sfile, simplifyVector = FALSE)
          else list()
  summ$autotune <- list(recall = ing$recall, missed = ing$missed,
                        suggestions = sug)
  jsonlite::write_json(summ, sfile, auto_unbox = TRUE, pretty = TRUE)
  cat(sprintf("Gold ingest: %d missed; %d suggestion(s).\n",
              ing$missed, nrow(sug)))

  if (getflag("--apply-tunings")) {
    if (is.na(actor) || !nzchar(actor))
      stop("--apply-tunings requires --actor")
    proj <- se_autotune_apply(proj, sug, actor = actor)
    cat(sprintf("Applied %d tuning(s); policy version now %d.\n",
                nrow(sug), proj$policy$version))
  }
}
```

> `project_dir`, `plan`, `actor`, `getopt`, `getflag` must match the names already used in `batch_cli.R`. If the CLI uses different identifiers (e.g. `proj_dir`), rename accordingly. Ensure `--gold`/`--apply-tunings` are documented in the CLI's own usage/help text if it prints one.

- [ ] **Step 4: Run it and confirm it passes** — `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add app/batch_cli.R
git commit -m "$(printf 'Autotune: CLI --gold ingest and optional --apply-tunings\n\n--gold diffs a ground-truth table after the run, writes per-identifier\nrecall + suggestions into batch_summary.json. --apply-tunings applies\nthem headless (requires --actor). Both off by default.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 12: Improvement tab + miss capture (Shiny UI)

Surface the loop for the reviewer. UI logic is thin over the tested core.

**Files:**
- Modify: `app/app.R` (add a nav panel after the "Batch" panel, line ~313; add server logic)
- Test: manual browser smoke (Shiny UI has no headless self-test path in this repo)

- [ ] **Step 1: Add the nav panel** — after the `nav_panel("Batch", ...)` block, add:

```r
  nav_panel("Improvement", icon = icon("wand-magic-sparkles"),
    layout_sidebar(
      sidebar = sidebar(
        h6("Toggles"),
        input_switch("at_global_register", "Cross-project global register", FALSE),
        input_switch("at_learned_regex", "Learned-regex generation", FALSE),
        textInput("at_register_dir", "Register folder (aggregate-only)", ""),
        hr(),
        h6("Mark a missed identifier"),
        textInput("at_miss_file", "File", "s.csv"),
        textInput("at_miss_col", "Column", ""),
        textInput("at_miss_val", "Missed value", ""),
        selectInput("at_miss_id", "Identifier",
                    choices = names(se_default_identifiers())),
        actionButton("at_mark_miss", "Record miss", class = "btn-warning"),
        hr(),
        fileInput("at_gold", "Ground-truth file (csv)"),
        actionButton("at_ingest", "Ingest gold", class = "btn-primary")),
      card(card_header("Per-identifier recall"), DTOutput("at_recall")),
      card(card_header("Suggestions (approve, then apply)"),
        DTOutput("at_suggest"),
        actionButton("at_apply", "Apply approved", class = "btn-success"),
        actionButton("at_promote", "Promote to global register")),
      card(card_header("Applied tunings"),
        DTOutput("at_history"),
        actionButton("at_revert", "Revert selected", class = "btn-danger")))),
```

- [ ] **Step 2: Add server logic** — inside the server function (near the other reactive handlers), add handlers that call the tested core. Use the app's existing project reactive (find how the current project is held — likely `rv$proj` or similar — and reuse it):

```r
  # --- Improvement tab (Phase 9) ---
  observeEvent(input$at_mark_miss, {
    req(rv$proj)
    se_feedback_record_miss(rv$proj, file = input$at_miss_file,
      column = input$at_miss_col, row = NA_integer_, span = NULL,
      value = input$at_miss_val, identifier = input$at_miss_id,
      source = "reviewer", actor = input$role %||% "reviewer")
    showNotification("Miss recorded.", type = "message")
  })

  at_suggestions <- reactiveVal(NULL)

  observeEvent(input$at_ingest, {
    req(rv$proj, input$at_gold)
    gold <- utils::read.csv(input$at_gold$datapath, stringsAsFactors = FALSE,
                            colClasses = "character")
    ing <- se_autotune_ingest_gold(rv$proj, gold, inputs = NULL,
                                   actor = input$role %||% "reviewer")
    output$at_recall <- renderDT(ing$recall)
    at_suggestions(se_autotune_suggest(rv$proj))
    output$at_suggest <- renderDT(at_suggestions())
  })

  observeEvent(input$at_apply, {
    req(rv$proj, at_suggestions())
    sel <- input$at_suggest_rows_selected
    if (!length(sel)) { showNotification("Select suggestions to apply.",
      type = "error"); return() }
    rv$proj <- se_autotune_apply(rv$proj, at_suggestions()[sel, , drop = FALSE],
                                 actor = input$role %||% "reviewer")
    output$at_history <- renderDT(data.frame(
      tuning_id = names(rv$proj$policy$applied_tunings)))
    showNotification(sprintf("Applied. Policy version %d.",
      rv$proj$policy$version), type = "message")
  })

  observeEvent(input$at_revert, {
    req(rv$proj)
    ids <- names(rv$proj$policy$applied_tunings)
    sel <- input$at_history_rows_selected
    if (!length(sel)) return()
    rv$proj <- se_autotune_revert(rv$proj, ids[sel[1]],
                                  actor = input$role %||% "reviewer")
    output$at_history <- renderDT(data.frame(
      tuning_id = names(rv$proj$policy$applied_tunings)))
  })

  observeEvent(input$at_global_register, {
    req(rv$proj)
    rv$proj$policy$autotune$global_register <- isTRUE(input$at_global_register)
    se_project_save(rv$proj)
  })
  observeEvent(input$at_learned_regex, {
    req(rv$proj)
    rv$proj$policy$autotune$learned_regex <- isTRUE(input$at_learned_regex)
    se_project_save(rv$proj)
  })
  observeEvent(input$at_promote, {
    req(rv$proj)
    rv$proj$policy$autotune$global_register_dir <- input$at_register_dir
    out <- se_register_promote(rv$proj, at_suggestions(),
      register_dir = input$at_register_dir, actor = input$role %||% "reviewer")
    showNotification(if (isTRUE(out$written)) "Promoted to global register."
      else "Global register is off.", type = "message")
  })
```

> `rv$proj` and `input$role` are assumptions — before writing, grep `app.R` for how the current project object and the role selector are actually named (the role input exists: line 71). Adapt names to match. Ensure `input_switch` is available (bslib) — it is imported via `library(bslib)` in `global.R`.

- [ ] **Step 3: Browser smoke test**

Launch the app and confirm the Improvement tab renders with no Shiny error:

```bash
"C:\Program Files\R\R-4.5.2\bin\Rscript.exe" -e "shiny::runApp('app', port=7799, launch.browser=FALSE)"
```

Then use the in-app browser (`preview_start` / navigate to `http://127.0.0.1:7799`), open the **Improvement** tab, and verify: the two toggles render (default off), the miss-capture form renders, and the suggestions/history cards render empty without error. Check the R console for `Warning`/`Error`. (No assertion script — this is a visual smoke check because the repo has no Shiny test harness.)

- [ ] **Step 4: Commit**

```bash
git add app/app.R
git commit -m "$(printf 'Autotune: Improvement tab (toggles, gold, suggest/apply/revert)\n\nReviewer-facing surface over the tested autotune core: on/off toggles\n(default off), missed-identifier capture, gold ingest + recall, ranked\nsuggestions with approve->apply, applied-tuning history + revert, and\npromote-to-global-register.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 13: Documentation

**Files:**
- Modify: `docs/roadmap.md`, `docs/packaging.md`, `CLAUDE.md`

- [ ] **Step 1: `docs/roadmap.md`** — add a "Phase 9 — Feedback-driven detection tuning" section: what it does (capture → diagnose → suggest → approve → apply → detect; optional global register + learned regex, both default off), the PHI boundary, the new audit events, and the CLI flags.

- [ ] **Step 2: `docs/packaging.md`** — note that `feedback.enc` / `watchlist.enc` are project-local encrypted stores (travel with the project, never in the bundle) and that `--gold` / `--apply-tunings` exist on the batch CLI. No new bundle files.

- [ ] **Step 3: `CLAUDE.md`** — add `autotune.R` to the `app/R/` layout list with a one-line description:

```
    autotune.R     feedback-driven detection tuning: capture missed identifiers
                   (reviewer mark + gold diff), diagnose, suggest a fix
                   (threshold/watchlist/per-column/learned-regex), reviewer
                   approves -> versioned+audited apply; optional aggregate-only
                   cross-project register + learned-regex, both default off; raw
                   values AEAD-encrypted + project-scoped (feedback.enc/watchlist.enc)
```

Also add `autotune.R` to the `global.R` load-order note if one is present.

- [ ] **Step 4: Commit**

```bash
git add docs/roadmap.md docs/packaging.md CLAUDE.md
git commit -m "$(printf 'Docs: Phase 9 feedback-driven detection tuning\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Final verification (after all tasks)

- [ ] Re-run every scratchpad test (`t01`–`t11`) in one go; all print `ALL TESTS PASSED`.
- [ ] Run the existing clean-machine verifier to confirm no regression:
  ```bash
  "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" tools\verify.R
  ```
  Expect `VERIFY PASS` (the smoke batch de-id + audit chain still verify with `autotune.R` sourced).
- [ ] `git log --oneline` shows one commit per task, each with the co-author trailer.
- [ ] Confirm the remote is `structured_deidentification`, then (only on the user's OK) push the branch.

## Notes on scope / deferred

- **Rebuilding `sds_pf.zip`** to include Phase 9 is a packaging step, not part of this plan — do it after merge, on the user's request (the build prunes `docs/superpowers/`, so specs/plans never ship).
- **`se_register_suggest` UI surface** (showing cross-project priors when a new project targets the same identifiers) is implemented in the core (Task 9) but only wired into the CLI/tab minimally; a richer "prior suggestions" panel is a future enhancement, intentionally out of scope here (YAGNI).
