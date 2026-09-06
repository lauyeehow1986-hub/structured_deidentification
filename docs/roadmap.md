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

## Phase 5 — SDC (opt-in) ✅ core / ⬜ transforms UI
- ✅ k-anonymity, l-diversity, sample uniques (SUDA-lite), individual risk (sdcMicro), linkage
  **DCR**, and a hard **export gate** (`app/R/sdc.R`). All opt-in.
- ⬜ Interactive risk-reduction transforms (suppression, global recode, top/bottom coding,
  microaggregation, PRAM, noise); differential-privacy + synthetic-data (flexsynth) options.

## Phase 6 — Signed handoff + certificate + reports ✅ core / ⬜ PDF report
- ✅ Per-user signature on each stage; export/import signed project bundle (`.zip`); signed
  **de-identification certificate** (JSON) citing PDPA / HIPAA Safe Harbor / SingHealth-IRB.
- ⬜ Human-readable PDF certificate + full report.

## Phase 7 — PDF + XML + vendor ECG ⬜
- ⬜ Digital PDF true redaction (remove underlying text) → flattened PDF.
- ⬜ Scanned PDF → offline OCR (Tesseract) → region redaction.
- ⬜ XML tree scrub: generic + HL7 CDA / FHIR-XML + **Philips iECG/SierraECG** + **GE MUSE ECG**
  (scrub demographic/test-header PHI, preserve the waveform payload).

## Phase 8 — Batch + LLM + packaging ⬜
- ⬜ Batch runner over many files/projects.
- ⬜ Optional Ollama LLM pass.
- ⬜ Transitively-closed portable bundle (portable R + Python + Tesseract) as an unzip-and-run
  zip; end-to-end verification on a clean machine.

## Open item
- Replace the interim HIPAA-adapted default identifier set with the **canonical 15 SingHealth
  identifiers** (paste them in; the set is editable so this does not block earlier phases).
