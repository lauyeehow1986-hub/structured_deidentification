# Phase 8 — Batch runner + MAX_PATH-safe portable packaging

Date: 2026-09-06
Status: approved design (pending spec review)

## Goal

Close the roadmap with Phase 8:

1. A **batch runner** over many files / a whole folder, driving the existing per-file
   pipelines (structured tables *and* PDF/XML/ECG documents) into one project's
   outputs / manifest / audit trail — usable headless (CLI) and from the UI.
2. Confirm the **optional Ollama LLM pass** works in batch (the backend already exists
   from Phase 2; this is wiring + docs, not new detection code).
3. A **transitively-closed portable bundle** (portable R + optional bundled Python) that
   unzips into the user's `Downloads` and runs by double-click, **guaranteed not to exceed
   the Windows MAX_PATH (260) limit** on the locked-down target, plus end-to-end
   verification.

## Non-negotiable constraints (unchanged)

- **Deployed bundle is air-gapped: no network calls ever at runtime.** The *build* laptop
  is connected and may `install.packages` / pip — that is the documented build recipe, not
  a runtime dependency.
- Heavy detection (NER/LLM) runs **out-of-process** (subprocess of bundled `python.exe`),
  never reticulate (Windows OpenSSL `no OPENSSL_Applink` crash). Never call
  `reticulate::py_available(initialize=TRUE)`.
- `se_` prefix, `snake_case`; core `app/R/*.R` pure and independently testable.
- Repo commits **no tests** and **no real PHI**; ad-hoc self-tests live in the scratchpad.
- Do **not** run `Rscript -e` with long multiline scripts on this box (segfaults) — use
  committed script files.
- AV quarantines unsigned `bin/llama/*.exe` → `bin/llama/` is excluded from the default
  auto-built zip; the LLM pass stays opt-in / sneakernetted.
- Git commit trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; do not stage
  `.claude/`. ASK before committing/pushing.

## The MAX_PATH problem (headline requirement)

Windows classic limit is **260 chars for an absolute path**; the locked-down target box
**cannot enable long-path support**, so the bundle must fit *by construction* when extracted
into `Downloads`.

Budget math (worst-case):

- Assumed install root `C:\Users\<user>\Downloads\sds\` ≈ **44 chars** for a ~20-char
  username (`C:\Users\` = 9, user ≈ 20, `\Downloads\sds\` = 15).
- Current deepest **relative** path in the staged tree = **159**
  (`bin/python/Lib/site-packages/presidio_analyzer/.../*.pyc`) → ~203 absolute. Fits.
- **Hazard:** once R is bundled, header trees such as
  `bin/R/library/BH/include/boost/geometry/...` run 200+ relative → **over 260**.

### Fix — three build-time levers (no registry / no long-path reliance)

1. **Short root** `sds` (extract as `C:\Users\<you>\Downloads\sds`). Every saved char is
   headroom; the auditor assumes this root.
2. **Prune runtime-unneeded deep subtrees** while building the bundle:
   - R library packages: drop `include/`, `help/`, `html/`, `doc/`, `tests/`, `examples/`,
     `po/`, `Meta/vignette.rds` (keep `libs/`, `R/`, `DESCRIPTION`, `NAMESPACE`,
     `Meta/package.rds`, and data). Dropping `include/` removes the boost/Eigen depth
     monsters *and* shrinks the zip substantially.
   - Python site-packages: drop `__pycache__/`, `*.pyc`, `tests/`, `test/`, `include/`
     (keep `*.dist-info/METADATA` for the closure check).
3. **Build-time path auditor** that computes worst-case absolute length
   (`len(assumedRoot) + 1 + len(relPath)`) for every file and **fails the build** if any
   exceeds budget. Target ≤ **240** (warn), hard ceiling **255**. Also runnable
   post-extraction against the operator's *actual* root.

Tesseract needs **no separate `bin/`**: the R `tesseract` / `magick` / `pdftools` packages
bundle their own native libs on Windows; we only stage `tessdata/eng.traineddata`. (Corrects
the roadmap's "portable R + Python + Tesseract" wording.)

## Architecture / components

### 1. `app/R/batch.R` (pure R, testable)

- `se_batch_plan(inputs, opts = list())` → data.frame of items
  `{path, type, action, rel}`. Routing by extension/content: `.csv`/`.xlsx` → `table`
  (detect→policy→de-identify); `.pdf` → `pdf`; `.xml` → `xml`. `inputs` may be a directory
  (optionally recursive) or an explicit vector of paths. Unknown types → `skip` with a note.
- `se_batch_run(proj, plan, opts = list(), progress = NULL)` → runs each item through the
  **existing** pipelines:
  - `table`: register input → `se_detect_*` (rules always; NER/LLM per `opts$use_ner` /
    `opts$use_llm` / `opts$llm_backend`) → apply the project policy via the Phase 3
    checkpoint engine (`se_deidentify` / chunked) → output to `outputs/`.
  - `pdf`: `se_pdf_redact_file`. `xml`: `se_xml_scrub_file`.
  - Per item: SHA-256 into the manifest, audit `batch_item` + the underlying action, elapsed
    time, findings/rows/pages, status `ok|error|skipped`. **Fail-soft**: a bad file is
    recorded and the batch continues.
  - **Idempotent**: skip an item whose output already exists in the manifest with the same
    input SHA (safe re-run / resume). Large tables further resume via existing checkpoints.
  - **Parallel**: items fan out over `future.apply::future_lapply` when `opts$workers > 1`,
    with a clean sequential fallback (mirrors `checkpoint.R`).
  - Returns `list(items = <status df>, totals = <counts>, started, finished)`.
- `se_batch_write_summary(result, dir)` → `batch_summary.json` + `batch_summary.csv`.
  (A PDF batch report is out of scope — YAGNI; the per-project certificate already covers
  the formal artifact.)

### 2. CLI — `run_batch.ps1` (+ `run_batch.bat`) and `app/batch_cli.R`

- `run_batch.ps1` locates bundled/system Rscript (shared with `run.ps1`) and invokes
  `Rscript app/batch_cli.R <args>`.
- `app/batch_cli.R` (committed script file — never `Rscript -e` multiline): parses
  `commandArgs`: `--project <dir>` (open or create), `--inputs <dir|glob|list>`,
  `--recursive`, `--workers N`, `--ner`, `--llm`, `--llm-backend llamacpp|ollama`,
  `--actor NAME`, `--strict`. Runs `se_batch_plan` + `se_batch_run`, prints a summary table,
  writes the summary files, exits non-zero if any item errored (always under `--strict`;
  otherwise only on hard failure).

### 3. Batch tab — `app/app.R`

- New `nav_panel("Batch", ...)`: requires an open project; choose an input folder or
  registered inputs, toggles (recursive, workers, NER, LLM + backend), **Run** →
  `se_batch_run` with a reactive progress callback → per-item status `DT` + a download button
  for the summary. Audit-logged. Reuses `rv$proj`.

### 4. Packaging tooling — `tools/`

- `tools/build_bundle.ps1`: assemble `dist/sds/` from repo + staged `bin/` + `models/` +
  a built portable R library → prune (lever 2) → run auditor (lever 3, abort on fail) → run
  closure check (abort on missing) → zip to `dist/sds.zip` (via `tar.exe`/`Compress-Archive`).
  Flags: `-IncludePython` (default on if `bin/python` present), `-IncludeLlama` (default
  **off**), `-Root` (assumed install root for the audit).
- `tools/stage_r.ps1`: on the connected build laptop, materialise a **relocatable R** under
  `bin/R` — copy the R 4.5.2 runtime and `install.packages()` the exact dependency set into
  `bin/R/library` (documented list), then prune. (Connected-build step; not shipped.)
- `tools/audit_pathlen.ps1`: worst-case path report (top-N longest, max, PASS/FAIL vs
  budget), `-Root` override; usable at build time and post-extraction on the real box.
- `tools/check_closure.ps1`: **R** — read each bundled package DESCRIPTION
  `Imports`/`Depends`/`LinkingTo`, assert each non-base dependency is present in
  `bin/R/library` (transitive). **Python** — parse `*.dist-info/METADATA` `Requires-Dist`
  (dropping extras / unsatisfied env-markers), assert presence in site-packages. Reports the
  missing set (the AndyFishing "closure or it breaks on the target" lesson).
- `tools/verify_clean_machine.ps1`: run **on the target** after extraction — path audit
  against the real root; launch bundled R and `library()` each critical package; if Python is
  bundled, `se_py_probe()` reports ready; a **smoke de-id** of a bundled sample produces
  output with a valid manifest + verifiable audit chain. Emits PASS/FAIL. This is the
  "clean-machine verification" deliverable.

### 5. Docs

- `docs/packaging.md`: bundle layout, `stage_r`/`build_bundle` steps, the prune list, the
  MAX_PATH budget math + extraction guidance (prefer Win11 `tar.exe -xf`, keep the root
  short), and the clean-machine checklist mapping to `verify_clean_machine.ps1`.
- Update `docs/roadmap.md` (Phase 8 → done; fix the "+ Tesseract" wording) and `CLAUDE.md`
  (add `batch.R`, `tools/`, `run_batch.*`).

## What actually gets built + verified in this session

Because the build laptop is connected:

- Build `app/R/batch.R`, `app/batch_cli.R`, `run_batch.*`, the Batch tab, and all `tools/`
  scripts + docs.
- Prove the batch engine headless against synthetic mixed-type inputs.
- Run `audit_pathlen.ps1` / `check_closure.ps1` against a **real** staged tree (stage a
  portable R via `stage_r.ps1`, so the auditor runs against an actual R library — no synthetic
  stand-in), then `build_bundle.ps1` to produce a real `dist/sds.zip`.
- Run `verify_clean_machine.ps1` against a freshly extracted copy at a realistic
  `Downloads\sds` path as a strong local proxy for the operator's clean-machine run.

Staged runtimes (`bin/`, `models/`, `dist/`) remain **git-ignored**; only code + docs are
committed.

## Testing (scratchpad — repo commits no tests)

- `test_batch.R`: `se_batch_plan` routing; `se_batch_run` over a temp project with mixed
  csv + xml (+ pdf fixture); idempotent re-run skips completed items; fail-soft on a bad
  file; parallel == sequential; manifest + audit updated; summary files written.
- `test_batch_tab.R`: `testServer` — Run → status table populated → summary download → audit
  action recorded.
- Path auditor / closure checker / verifier: exercised live in PowerShell against the staged
  tree, including a deliberately over-budget path to prove the auditor fails closed.

## Out of scope (YAGNI)

- A rendered PDF batch report (per-project certificate already exists).
- Bundling a separate Tesseract binary (rides inside the R packages).
- Auto-shipping `bin/llama/` in the default zip (AV-quarantine; opt-in sneakernet).
- Any change to detection/transform logic — Phase 8 orchestrates and packages existing code.
