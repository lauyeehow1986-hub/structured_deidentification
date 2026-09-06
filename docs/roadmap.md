# Roadmap — Structured De-identification System

Status legend: ✅ done · 🚧 in progress · ⬜ planned

## Phase 0 — Reset & scaffold ✅
- ✅ Removed the unrelated Slice-AR content that seeded this repo.
- ✅ New project scaffold: `app/` (Shiny UI + `R/` core + `python/`), `samples/`, `docs/`,
  launcher, `.gitignore`/`.gitattributes`, `CLAUDE.md`, `README.md`.
- ✅ Synthetic sample with planted + misplaced PII (`samples/make_sample.R`).

## Phase 1 — Projects + import + crypto core ✅
- ✅ Portable project folder: `project.json`, `inputs/ outputs/ work/ keys/ signatures/`,
  `manifest.json`, `audit.log`, `crosswalk.enc` (`app/R/project.R`, `keystore.R`).
- ✅ Crypto core, all self-tested (`app/R/crypto.R`): keyed HMAC pseudonyms (global/project
  scope), Feistel **FPE** (reversible, format-preserving), AEAD crosswalk (fails closed on wrong
  key), ed25519 detached signatures.
- ✅ Tamper-evident hash-chained audit log (`app/R/hashchain.R`) — verified detects edits.
- ✅ Import CSV/XLSX with SHA-256 registration into the manifest.

## Phase 2 — Detection + review ✅
- ✅ Deterministic detectors + validators incl. real **NRIC/FIN checksum** (`app/R/detect_r.R`).
- ✅ Column profiling + **misplaced-PII / outlier detection** (`app/R/profile.R`) — proven to
  catch an NRIC in a procedure-date and a serial-number column.
- ✅ Review surfaces: outlier table + free-text findings + auto column→identifier suggestion.
- ✅ **Explicit "Enable offline NER" probe, never auto-provisioned, run out-of-process.** The
  Detect tab has an Enable-NER button that probes the **bundled** interpreter (`se_py_probe`), plus
  opt-in checkboxes for NER and the local LLM. The engine runs as a **subprocess** of
  `bin/python/python.exe` (`app/python/run_engine.py`, JSON in/out) — *not* reticulate, because on
  Windows R's OpenSSL and a standalone Python's OpenSSL cannot share one process. Startup stays
  passive (file-existence only); the app never calls `py_available(initialize=TRUE)` or triggers
  uv/pip. Free-text detection merges deterministic rules (always) + Presidio/spaCy NER + the LLM
  into one findings table (`se_detect_freetext` / `se_dedup_findings`), each span tagged by detector
  (`rule:*` / `ner:presidio` / `llm:ollama`). All engines **fail closed to empty** when absent.
  Two air-gap hardenings baked in: the `ner`/`probe` runner modes **hard-disable outbound sockets**,
  and Presidio uses a **spaCy-NER-only registry** so its `tldextract`-backed email recognizer can't
  fetch the public-suffix list over the network. Bundling recipe: [docs/ner_packaging.md](ner_packaging.md).
- ✅ Optional local **LLM pass** for ambiguous free text, **off by default**, two backends
  (`app/python/detect_llm.py`, `se_llm_scan` / `se_llm_config`). Default is a **socket-free
  bundled llama.cpp** — a one-shot `llama-cli` subprocess against an auto-discovered
  `bin/llama/` binary + a single `models/llm/*.gguf` (medical default **MediPhi-Instruct Q4_K_M**,
  MIT, ~2.4 GB — extraction-tuned, best free-text name recall in the A/B; **Qwen2.5-3B-Instruct
  Q4_K_M**, Apache-2.0, ~2.1 GB is the generalist fallback; both fit a 16 GB CPU box); zero-config
  "drop it in the bundle and it runs". The
  runner disables outbound sockets for the llama.cpp backend too — only the alternative **Ollama**
  backend is allowed a loopback socket to a local service the operator chose to run. Findings are
  labelled hints (`llm:llamacpp` / `llm:ollama`, confidence ~0.6), never ground truth. Verified
  live on the staging box: R→subprocess→llama.cpp (Qwen2.5-3B) tags "John Tan"/phone spans; the
  bundled binary + GGUF are `.gitignore`d and sneakernetted. ⚠️ AV (Defender/AVG/McAfee) may
  quarantine the unsigned `llama*.exe` — exclude `bin/llama/`.
- ✅ **Verified end-to-end on a connected staging box** with a real bundle: a relocatable
  python-build-standalone CPython 3.12 under `bin/python/` + `presidio-analyzer` + `spacy` +
  `en_core_web_lg`. `se_py_probe()` reports ready and the R→subprocess→Presidio path finds names
  and locations that the rules miss (e.g. "John Tan", "Sarah Lim", "Singapore") merged alongside the
  rule hits. Also verified headless: merge/dedup, rules-only equivalence, fail-closed when the
  interpreter is absent, the socket guard actually blocks outbound, and `testServer` for the full
  Detect-tab wiring (rules-only forced path *and* the live NER path). The bundle itself is
  `.gitignore`d (`/bin/`, `/models/`) — code + docs are committed, the interpreter is sneakernetted.

## Phase 3 — Policy + de-identify engine ✅
- ✅ Per-column policy → actions: pseudonymize / **FPE (optional)** / generalize (date→year,
  age→band, geo→sector) / redact / **free-text targeted redaction** (`app/R/deidentify.R`).
- ✅ Crosswalk captured for reversible actions; authorised re-identification proven.
- ✅ Chunked checkpoints + parallel workers + mid-job **resume** for large files
  (`app/R/checkpoint.R`): row-sliced processing writes each slice to `work/<file>/` with a
  `progress.json` ledger, so a killed/power-lost run — or the drive **moved to another machine** —
  resumes from the first unfinished slice. Slices are independent, so they fan out over
  `future`/`future.apply` workers when asked (clean sequential fallback). CSV without embedded
  newlines is read one slice at a time (bounded memory); quoted-newline CSV and XLSX fall back to
  a single correct read. Verified headless: chunked == whole-table, resume-after-kill,
  resume-after-folder-move, parallel == sequential, embedded-newline & XLSX paths. Wired into the
  De-identify tab (rows/chunk, parallel workers, live progress, resume status).
- ✅ **Review and SDC are memory-bounded for large outputs too.** The finished output is only held
  in memory when it is small (`se.deid_inmem_max`, default 200k rows); above that it stays on disk
  and is read through bounded readers (`se_open_table` / `se_read_window` / `se_sample_table` in
  `checkpoint.R`). Review pages a row-window (original vs de-identified read side-by-side from both
  files); SDC estimates risk from a representative, capped block sample (`se.sdc_sample_cap`,
  default 20k) with DCR run against the row-aligned original blocks, and clearly labels its output
  as an estimate (and the export gate as sample-based) whenever sampling was applied. Verified
  headless + via `testServer`: window reads are exact and row-aligned, sampling is bounded,
  reproducible, RNG-isolated and disjoint, and both the in-memory and paged/sampled paths render.

## Phase 4 — Reviewer workflow + audit ✅ core
- ✅ Role gating (de-identifier vs reviewer), side-by-side original↔de-identified review,
  approve/return, audit viewer + chain verification, manifest viewer.

## Phase 5 — SDC (opt-in) ✅
- ✅ k-anonymity, l-diversity, sample uniques (SUDA-lite), individual risk (sdcMicro), linkage
  **DCR**, and a hard **export gate** (`app/R/sdc.R`). All opt-in.
- ✅ **Interactive risk-reduction transforms** (`app/R/sdc_transforms.R`), all opt-in, wired
  into the Disclosure-control tab with a **Preview → Apply → measure** loop: each transform
  shows its effect on k-anonymity *before* you commit, then stacks onto a treated copy of the
  working table; the measures and export gate re-run on the treated table, and it downloads as
  CSV (logged to the audit trail as `sdc_transform` / `sdc_export_treated`). Transforms:
  - **Local suppression** — blanks the quasi cells of every below-k record to force k-anonymity.
  - **Global recode / banding** — numeric → bands (break points + labels); categorical → mapping.
  - **Top / bottom coding** — caps extreme (identifying) values at a percentile or absolute cut.
  - **Microaggregation** — individual-ranking groups of ≥ *aggr*, replaced by group mean/median
    (short tail merged so no singleton; integer columns rounded back).
  - **PRAM** — post-randomisation: keep each categorical value with prob *p*, else redraw from
    the column marginal; reproducible by seed.
  - **Noise addition** — Gaussian (fraction of SD) or **Laplace / DP-style** (clamp to a range
    and calibrate scale to ε); integer columns rounded, reproducible by seed.
  - **Synthetic replacement** — pure-R independent-marginal resynthesis (breaks the joint quasi
    combination); uses the author's **flexsynth** for joint-preserving synthesis when installed,
    otherwise falls back to marginal with a note.
  Transforms operate on the same bounded working sample as the measures (so treated rows stay
  row-aligned with the original for DCR); on a large output this is analysis-only and clearly
  labelled. Headless + `testServer` suites cover every transform, reproducibility, the
  Preview/Apply/Reset/measure wiring, and that a treatment can drive the gate to PASS.

## Phase 6 — Signed handoff + certificate + reports ✅
- ✅ Per-user signature on each stage; export/import signed project bundle (`.zip`); signed
  **de-identification certificate** (JSON) citing PDPA / HIPAA Safe Harbor / SingHealth-IRB.
- ✅ **Human-readable PDF certificate + full report** (`app/R/report.R`), rendered **offline in
  pure R** via the base `grDevices::pdf()` device — no pandoc, LaTeX, headless browser, or
  network, so the air-gapped box that runs the app also emits the certificate. Split into a
  testable data half and a rendering half:
  - `se_cert_data(proj, paths)` assembles the certificate content — a **superset** of the legacy
    `certificate.json` fields, so the JSON stays backward compatible — including the column
    de-identification policy, the SHA-256 file manifest, per-signature **verification** status
    (each detached signature is re-verified), audit-action counts, any opt-in SDC actions, and
    the tamper-evident **chain-verification** result.
  - `se_report_pdf(cert, file)` paginates it onto A4 with a small cursor-based layout engine
    (word-wrapped paragraphs, key/value rows, bulleted lists, and tables that repeat their
    header across page breaks), a title block, per-page footers, and a boxed disclaimer.
  - Wired into the **Sign-off** tab: "Generate certificate" writes the JSON and caches the data;
    "Download … (PDF)" renders the report and logs a `certificate_pdf` action to the audit trail.
  - ASCII-only drawn text and a vector bullet marker (no Symbol-font glyphs) keep rendering
    robust on a locked-down viewer. Headless + `testServer` suites confirm the assembled data,
    the rendered PDF's text content (via `pdftools`), pagination, and the download wiring.

## Phase 7 — PDF + XML + vendor ECG ✅
Pure-R, air-gap safe, in-process (pdftools / tesseract / magick / xml2 are bundled R
packages — no subprocess, no network, no AV-quarantined binary). Wired into a new
**Documents** tab and, when a project is open, written to `outputs/`, hashed into the
manifest, and logged in the audit trail (`xml_scrub` / `pdf_redact` actions).
- ✅ **Digital PDF true redaction** (`app/R/pdf_redact.R`). Word boxes from
  `pdftools::pdf_data`; deterministic detectors locate PII; each page is rendered to a
  raster, the PII boxes are painted solid, and the pages are reassembled as an
  **image-only PDF** — the original text/vector layer is dropped entirely, so redacted
  content cannot be recovered by copy-paste, text extraction, or removing a box.
  A post-redaction guard OCRs each painted region and **fails closed** if a target is
  still readable. Detectors are pluggable (`scan_fn`) so an NER/LLM-backed scanner can be
  supplied to also catch free-text names.
- ✅ **Scanned / image-only PDF** → offline **Tesseract OCR** word boxes
  (`tesseract::ocr_data`), same redact/flatten pipeline. Auto-selected per page when
  there is no text layer; `force_ocr` forces it.
- ✅ **XML tree scrub** (`app/R/xml_scrub.R`): generic + HL7 CDA + FHIR + **Philips
  SierraECG / iECG** + **GE MUSE ECG**. Profile auto-detected from root/namespace;
  all XPaths use `local-name()` so vendor namespace prefixes never break matching.
  Demographic / test-header PHI (patient name, ID, DOB→year, acquisition date→year /
  time redacted, institution / site / department / operator / over-reader) is
  pseudonymized / generalized / redacted, while the **waveform payload is preserved
  byte-for-byte** — the scrubber never selects a waveform node and a post-scrub guard
  asserts every protected node is unchanged (fails closed; `se_xml_scrub_file` refuses
  to write otherwise). A high-precision value-level sweep (NRIC/email/phone/postal)
  catches stray PHI in free-text nodes outside the protected subtree.
- ✅ Synthetic fixtures + headless self-tests: `samples/make_xml_samples.R` (five
  profiles with planted fake PHI + a distinctive waveform blob); XML, PDF, and
  `testServer` Documents-tab suites all pass (header PHI removed, waveform preserved,
  keyed pseudonyms stable, flattened output has no recoverable text, OCR guard confirms
  targets unreadable while clinical text survives).

## Phase 8 — Batch + LLM + packaging ✅
- ✅ **Batch runner** over many files (`app/R/batch.R`). `se_batch_plan` routes each input by
  type; `se_batch_run` drives the *existing* pipelines — CSV/XLSX through the Phase-3
  chunked/resumable/parallel engine, PDF through Phase-7 true redaction, XML/ECG through the
  waveform-preserving scrub — into **one** project's `outputs/`, merged crosswalk, SHA-256
  manifest, and hash-chained audit (`batch_item` / `batch_run` actions). **Fail-soft** (a bad
  file is an `error` row, the run continues), **idempotent** (skips files already output unless
  `force`; re-decrypts and merges the prior crosswalk so a resumed run never loses mappings),
  and **parallel** over `future.apply`. Two surfaces on the same engine: a headless CLI
  (`app/batch_cli.R` + `run_batch.ps1`/`.bat`, `--project/--inputs/--recursive/--workers/
  --out-format/--actor/--force/--strict`, writes `batch_summary.{json,csv}`) and a **Batch tab**
  (input folder, recurse, workers, force, per-item status table, summary download).
- ✅ **Optional Ollama LLM pass** — the socket-permitted loopback Ollama backend already exists
  from Phase 2 (`detect_llm.py` / `se_llm_config`); batch and detection route to it via the
  same opt-in toggles. No new detection code.
- ✅ **Transitively-closed portable bundle + clean-machine verification** (`tools/`). A
  relocatable R (runtime + the transitive `Depends`/`Imports`/`LinkingTo` closure, staged by
  `stage_r.ps1` with no compilation) plus the optional bundled Python. `build_bundle.ps1`
  assembles → **prunes** runtime-unneeded deep subtrees (R `include/ doc/ html/ help/ tests/`,
  Python `__pycache__/`) → **audits worst-case path length** (`audit_pathlen.ps1`) → checks the
  **dependency closure** (`check_closure.ps1`, R + Python) → zips (native .NET `ZipFile`).
  `verify_clean_machine.ps1` runs on the target: path audit against the real root, every R
  package loads from the bundle alone (per-user library neutralised), and a smoke batch de-id
  whose audit chain verifies.
  - **MAX_PATH-safe by construction** (the box can't enable long-path support): short root
    (`Downloads\sds`) + pruning the Eigen/Armadillo header depth keep the worst-case absolute
    path to **163** at a real `Downloads\sds` (well under 260). The build fails closed if the
    audit or closure check trips. Verified end-to-end: `sds.zip` (~667 MB, R + Python) extracts
    into `C:\Users\<user>\Downloads\sds` and passes `verify_clean_machine.ps1`.
  - Tesseract/poppler/ImageMagick ride **inside** the R `tesseract`/`pdftools`/`magick`
    packages (no separate binary); `bin/llama/` is excluded from the default zip (AV
    quarantines the unsigned exes) and sneakernetted separately. See
    [docs/packaging.md](packaging.md).

## Open item
- **Closed (2026-09-06).** The default identifier catalogue in `app/R/identifiers.R`
  (`se_default_identifiers()`) is the **canonical 15 SingHealth identifiers** (PDPA + HBRA):
  names; NRIC/FIN/passport/birth-cert; MRN; case/visit/episode; address; postal code; phone;
  fax; email; date of birth (year only); date of death; device/serial; biometric;
  full-face photo; other unique identifier/code. It remains **editable per project** via the
  Policy tab, so a site can swap in a revised institutional list at any time without a code
  change.
