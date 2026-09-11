# Feedback-driven detection tuning (auto-improvement) — Design

**Date:** 2026-09-11
**Status:** Approved for planning
**Module:** Phase 9 — `app/R/autotune.R` (+ small hooks in `detect_r.R`, `deidentify.R`,
`project.R`, `app.R`, `batch*.R`)

## Context

The structured de-identification tool detects the 15 SingHealth identifiers with
deterministic rules (`detect_r.R`), column profiling (`profile.R`), and the default
Privacy Filter free-text detector (`engine_py.R`). A two-person workflow reviews
each run. Today the Review tab captures only **false positives** — a reviewer can
*reject* a detected value (`rv$ft_rejects` → `policy$freetext_opts$rejects`). There
is no path to record a **missed** identifier (a false negative), and nothing feeds
past misses back into future runs.

This module closes that loop: **capture misses → diagnose why → suggest a concrete
fix → reviewer approves → apply (versioned + audited) → future runs improve.**

## Goals

- Learn from identifiers missed in previous runs and tag them for improvement.
- Two capture sources: **reviewer marking** (in-loop) and **ground-truth diffing**
  (optional labelled file → per-identifier recall).
- **Suggest, human-approves** autonomy: nothing changes behaviour until a reviewer
  approves; every applied change is versioned, audited, and reversible.
- Four tuning levers: **confidence thresholds**, **per-project value watchlist**,
  **per-column detector enable**, **learned regex patterns**.
- **Cross-project global register** (aggregate-only) — **toggleable**, default off.
- **Learned-regex auto-generation** — **toggleable**, default off.

## Non-goals

- No online/neural learning, no model fine-tuning, no network. "Learning" is
  deterministic aggregation + threshold/pattern heuristics, fully inspectable.
- No auto-apply without reviewer approval.
- No cross-project sharing of raw values, ever.

## Hard constraint — PHI boundary (non-negotiable)

A raw missed value is PHI. Therefore:

- **Raw values** (feedback records, the watchlist) live **only** in the project
  folder, **AEAD-encrypted** (reuse `crypto.R`, same custody as the crosswalk).
- The **global register is aggregate-only**: per-identifier counts, recall trend,
  threshold recommendations, and *generalized* patterns — **never a literal value**.
  `se_register_promote()` asserts no literal PHI is present and refuses otherwise.
- `learned_patterns` are generalized PCRE (e.g. `\b[XY][0-9]{7}[A-Z]\b`), stored in
  the project policy; only generalized patterns (never watchlist literals) may be
  promoted to the global register.

## Architecture

```
capture ──► diagnose ──► suggest ──► (reviewer approves) ──► apply ──► detect
  │                                                            │
  ├ reviewer mark (Review tab)                                 ├ policy delta (versioned)
  └ gold-file diff (Improvement tab / --gold)                  ├ audit event
                                                               └ optional promote → global register
```

Pure R, offline, deterministic. Reuses `crypto.R` (AEAD), `hashchain.R` (audit),
`project.R` (policy + versioning), `detect_r.R` (detectors), `profile.R`.

## Data model

### Project feedback store (PHI — encrypted, project-scoped)
`<project>/feedback.enc` — append-only, AEAD-encrypted. One record per miss:
`{ts, actor, source: "reviewer"|"gold", file, column, row, span, value, identifier,
why_missed, run_id, tuning_id?}`. `why_missed` is filled by diagnosis.

### Project watchlist (PHI — encrypted, project-scoped)
`<project>/watchlist.enc` — `{identifier, value}` literals to always catch on
re-runs of this project. Decrypted into an in-memory detector at run time only.

### Project policy additions (`project.json`, non-PHI)
- `policy$conf_overrides` — named per-identifier confidence floors.
- `policy$columns[[col]]$force_detectors` — detectors to force-scan in a column.
- `policy$learned_patterns` — `list({identifier, pattern, tuning_id, added_by, ts})`.
- `policy$autotune` — toggles + params:
  `list(global_register=FALSE, learned_regex=FALSE, global_register_dir=NULL,
        min_support=2L, max_fp=0L)`.
- `policy$version` — bumped on every apply (reproducibility).

### Global register (aggregate-only — no PHI; toggleable)
`<global_register_dir>/register.json` (chosen by the operator, outside any project):
`list(identifier, lever, miss_count, projects, recall_samples, threshold_reco,
patterns[generalized], updated_ts)`. Written only when `global_register=TRUE` and the
operator promotes an entry.

## Components (`app/R/autotune.R`, `se_` prefix, snake_case)

### Config / paths
- `se_autotune_config(proj)` → merged toggles/params with defaults.
- `se_autotune_paths(proj_dir)` → `feedback.enc`, `watchlist.enc`, register dir.

### Capture
- `se_feedback_record_miss(proj, file, column, row, span, value, identifier,
  source, actor)` — append encrypted record + audit `feedback_miss_marked`.
- `se_autotune_ingest_gold(proj, gold, inputs=NULL, actor)` — re-detect the inputs,
  diff against `gold` (`data.frame(file, column, row|value, identifier)`), record
  every uncovered gold item as a `source="gold"` miss, return **per-identifier
  recall**. Audit `feedback_gold_ingested`.

### Diagnose
- `se_autotune_diagnose(proj)` — for each miss, re-run detectors/policy to classify
  `why_missed`:
  - `below_threshold` — a detector matched, confidence < the active floor.
  - `detector_off` / `wrong_column` — value matches a detector not enabled/scanned
    for that column (the misplaced-PII case).
  - `no_pattern` — nothing matches.
  - `known_value` — exact recurring literal.
  Returns a data.frame keyed by miss.

### Suggest (ranked, with safety preview)
- `se_autotune_suggest(proj, data=NULL)` — aggregate misses per identifier×cause
  (respecting `min_support`), emit ranked suggestions. Each:
  `{id, identifier, lever, evidence, delta (policy patch), safety}`.
  `safety` runs the proposed delta against the current `data` (when supplied) and
  reports `new_detections` and `false_positives` so over-redaction is visible before
  approval. Cause → lever mapping:
  - `below_threshold` → **threshold** (lower floor to just below the missed conf).
  - `detector_off`/`wrong_column` → **column_enable** (`force_detectors`).
  - `known_value` → **watchlist**.
  - `no_pattern` → **watchlist** + (if `learned_regex=TRUE`) **learned_regex**.
- `se_autotune_generalize(values, corpus=NULL)` — the regex generalizer (only when
  `learned_regex=TRUE`): tokenize each value (digit/letter/sep classes), abstract to
  a bounded character-class PCRE, anchor with `\b`, and apply a **specificity guard**
  (reject patterns that are too broad, e.g. match a large fraction of `corpus` or
  degenerate to `.*`). Returns `{pattern, coverage, false_positives}`; caps FP at
  `max_fp`. Always suggestion-only (never auto-applied).

### Apply / revert (reviewer-approved, versioned, audited)
- `se_autotune_apply(proj, approved, actor)` — merge approved deltas into policy,
  encrypt new watchlist values, bump `policy$version`, persist, audit
  `feedback_tuning_applied` with the full delta and a `tuning_id`.
- `se_autotune_revert(proj, tuning_id, actor)` — undo a prior apply; audit
  `feedback_tuning_reverted`.

### Global register (toggleable)
- `se_register_promote(proj, applied, register_dir)` — write aggregate-only entry;
  **assert no literal values** (strip watchlist; keep generalized patterns + stats).
- `se_register_suggest(proj, register_dir)` — surface cross-project priors as
  suggestions when a new project targets the same identifiers.

## Detection wiring (small, contained)

- `se_watchlist_detector(pairs)` in `detect_r.R` — build an exact-match detector from
  escaped literals (`\Q…\E`), high `base_conf`, correct `identifier`.
- `se_detectors(extra = list())` — append project extras (watchlist + learned
  patterns) to the shipped set. **Shipped detectors are never edited**, so default
  behaviour stays byte-for-byte reproducible.
- Scan path in `deidentify.R`: assemble `se_detectors(extra = c(watchlist,
  learned_patterns))`; honour per-column `force_detectors`; apply `conf_overrides`
  in the gating step. Batch path (`batch.R`) uses the same assembled set.

## Surfaces

### Review tab (`app.R`)
"Mark selected as missed PII" + an identifier dropdown → `se_feedback_record_miss`.

### New "Improvement" tab (`app.R`)
- Toggles: **Global register on/off**, **Learned-regex generation on/off** (persist
  to `policy$autotune`).
- Ground-truth: upload a gold file → "Ingest" → per-identifier recall table.
- Register table: miss counts + recall trend per identifier.
- Suggestions table: lever, evidence, **safety preview** (new detections / FP),
  approve checkboxes, "Apply approved".
- Applied-tuning history with **revert**.
- "Promote to global register" (enabled only when the global toggle is on).

### Batch / CLI (`batch_cli.R`, `batch.R`)
- `--gold <file>` — ingest ground truth after the run; suggestions written into
  `batch_summary.json`.
- `--apply-tunings` — optional headless apply (requires `--actor`); off by default.

## Determinism, audit, reproducibility

- Every behaviour change is an explicit, approved policy delta with a version bump.
- Audit events: `feedback_miss_marked`, `feedback_gold_ingested`,
  `feedback_tuning_applied` (+delta), `feedback_tuning_reverted`,
  `register_promoted`. All chain-verified by `hashchain.R`.
- Re-running a project at a pinned `policy$version` reproduces prior output.

## Testing (scratchpad self-tests; repo ships no tests)

1. `diagnose` classifies each `why_missed` (one constructed miss per cause).
2. Gold-diff recall computed correctly per identifier.
3. `suggest` emits threshold/watchlist/column/regex deltas with correct `safety`
   counts; honours `min_support`.
4. Apply → re-detect: a previously-missed value is now caught; `policy$version`
   bumped; audit chain verifies. `revert` restores prior policy + output.
5. Regex generalizer covers the misses, **rejects over-broad** patterns, FP count
   correct; toggle off ⇒ zero regex suggestions.
6. **PHI boundary:** global-register entry contains no raw values (assert);
   `feedback.enc` / `watchlist.enc` ciphertext on disk ≠ plaintext.
7. Toggles: global register off ⇒ no register writes; learned-regex off ⇒ generalizer
   never invoked.

## Files

- **New:** `app/R/autotune.R`; scratchpad self-tests.
- **Modify:** `detect_r.R` (watchlist detector + `extra=` hook), `deidentify.R`
  (consume extras/overrides/force_detectors), `project.R` (policy fields + version +
  store paths), `app.R` (Review action + Improvement tab), `batch_cli.R`/`batch.R`
  (`--gold`, `--apply-tunings`, suggestions in summary), `global.R` (source
  `autotune.R`), `docs/roadmap.md` (Phase 9), `docs/packaging.md` if surfaces change,
  `CLAUDE.md` (layout line).

## Open questions

None blocking. Defaults chosen: both toggles **off**; `min_support=2`; `max_fp=0`.
