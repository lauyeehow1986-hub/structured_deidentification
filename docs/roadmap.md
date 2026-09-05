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

## Phase 2 — Detection + review ✅ core / 🚧 NER packaging
- ✅ Deterministic detectors + validators incl. real **NRIC/FIN checksum** (`app/R/detect_r.R`).
- ✅ Column profiling + **misplaced-PII / outlier detection** (`app/R/profile.R`) — proven to
  catch an NRIC in a procedure-date and a serial-number column.
- ✅ Review surfaces: outlier table + free-text findings + auto column→identifier suggestion.
- 🚧 Bundle Python + Presidio/spaCy model for offline NER (contract ready: `python/detect_ner.py`,
  `R/engine_py.R`); wire an explicit "Enable NER" probe (never auto-provision).
- ⬜ Optional local **Ollama** LLM pass for ambiguous free text (off by default).

## Phase 3 — Policy + de-identify engine ✅ core / ⬜ scale
- ✅ Per-column policy → actions: pseudonymize / **FPE (optional)** / generalize (date→year,
  age→band, geo→sector) / redact / **free-text targeted redaction** (`app/R/deidentify.R`).
- ✅ Crosswalk captured for reversible actions; authorised re-identification proven.
- ⬜ Chunked checkpoints + parallel workers (`future`/`mirai`) + mid-job **resume** for large
  files (`work/` scaffolding present; engine to be added).

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
