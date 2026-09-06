# Structured De-identification System

An admin-operated **R Shiny** tool for de-identifying structured data (CSV, XLSX, tables) and
— in later phases — documents (PDF, XML incl. Philips iECG/SierraECG and GE MUSE ECG XML). It
removes/transforms the 15 SingHealth identifiers, catches PII that has been *misplaced* (e.g. an
NRIC typed into the wrong column) or buried in free text, and runs a two-person
de-identify → review workflow with a tamper-evident audit trail, SHA-256 manifests, and
digital-signature sign-off.

> ⚠️ **Not for clinical or diagnostic use.** For research/governance de-identification only. The
> data controller is responsible for confirming adequacy before release. **Never** load real
> patient data into a committed repo — use the synthetic `samples/` only.

## Key features
- **15-identifier catalogue** (the canonical SingHealth 15 under PDPA + HBRA), editable per project.
- **Detection**: deterministic rules + validators (real NRIC/FIN checksum, phone, email, dates),
  column profiling that flags **out-of-place values**, and optional offline **Presidio/spaCy NER**
  for free text.
- **Transforms** per field: keyed **pseudonym** tokens, **format-preserving encryption** (optional),
  **generalization** (dates→year, age→bands, postal→sector), **redaction**, and **targeted
  free-text redaction** (only the detected identifiers, not the whole cell).
- **Two key scopes**: `global` (link a person across projects) and `project` (isolated), with an
  AEAD-encrypted crosswalk for **authorised re-identification**.
- **Statistical disclosure control** (all opt-in): k-anonymity, l-diversity, sample uniques,
  individual risk (`sdcMicro`), linkage DCR, and a hard **export gate**.
- **Governance**: hash-chained `audit.log`, SHA-256 `manifest.json`, per-user signatures, and a
  signed **de-identification certificate** (PDPA / HIPAA Safe Harbor / SingHealth-IRB framing).
- **Portable, air-gapped, resumable**: the entire project lives in one folder on the data drive;
  no network calls; designed to unzip-and-run on a locked-down Windows box.

## Run (development)
```bash
Rscript -e "shiny::runApp('app', port=7788)"
```
Then open http://127.0.0.1:7788. Regenerate the synthetic sample with:
```bash
Rscript samples/make_sample.R
```

## Portable run
Use `run.ps1` (or `run.bat`) from the bundle root. On an air-gapped target, the bundle carries
its own R (and optional Python/Tesseract) under `bin/`; the launcher sets paths and opens the app
in the default browser. See [docs/roadmap.md](docs/roadmap.md) Phase 8 for packaging.

## Status
Phases 0–1 complete; detection, profiling, de-identify, crosswalk re-identification, manifest and
audit are proven end-to-end. See [docs/roadmap.md](docs/roadmap.md).
