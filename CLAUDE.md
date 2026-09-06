# CLAUDE.md — Structured De-identification System

## What this is
An **admin-operated R Shiny tool to de-identify structured data** (CSV, XLSX, tables) and,
in later phases, documents (PDF, XML including Philips iECG/SierraECG and GE MUSE ECG XML).
It removes/transforms the **15 SingHealth identifiers**, detects PII that has been *misplaced*
(e.g. an NRIC typed into a procedure-date or serial-number column) or buried in free text, and
enforces a **two-person workflow** (de-identifier + reviewer) with a **tamper-evident audit
trail, SHA-256 manifests, and digital-signature sign-off**.

Educational/research governance tool — **not for clinical or diagnostic use**. The data
controller remains responsible for confirming adequacy of de-identification before release.
**Never commit real patient data or DICOM/PHI** — only synthetic samples (`samples/`).

## Design constraints (non-negotiable)
- **Air-gapped, no-install:** must copy onto a locked-down Windows box and run by unzip +
  double-click. Everything is pure-R over pre-bundled packages; heavy detection (NER/OCR/LLM/PDF)
  runs in a **bundled** Python driven **out-of-process** — a subprocess of `bin/python/python.exe`
  running `app/python/run_engine.py` (JSON in/out), NOT reticulate: on Windows R's OpenSSL and a
  standalone Python's OpenSSL cannot share one process (the `no OPENSSL_Applink` crash). **No
  network calls, ever.** `app/R/engine_py.R` probes passively (checks for a bundled interpreter on
  disk) and only runs the subprocess on an explicit "Enable NER" click; the `ner`/`probe` runner
  modes hard-disable outbound sockets, and Presidio is restricted to a spaCy-NER-only registry so
  its `tldextract`-backed email recognizer can't fetch the public-suffix list. The optional LLM
  second-opinion pass defaults to a **socket-free bundled llama.cpp** (a one-shot `llama-cli`
  subprocess against an auto-discovered `models/llm/*.gguf` — medical default MediPhi-Instruct
  Q4_K_M (MIT, extraction-tuned), Qwen2.5-3B-Instruct Q4_K_M (Apache-2.0) the generalist fallback;
  multi-GGUF pick order `mediphi*`→`qwen2.5-3b*`→`qwen*`, see docs/ner_packaging.md; the `llm`
  runner mode disables sockets for every backend except a local loopback Ollama, the one optional
  exception). Never call `reticulate::py_available(initialize=TRUE)` or anything
  that triggers uv/pip provisioning.
- **Portable projects:** all project state lives in one self-contained folder on the data drive
  (see `app/R/project.R`), so a job can be unplugged and resumed on another machine.
- **Two key scopes everywhere:** `global` (link the same person across projects) and `project`
  (isolated). Re-identification is possible only via the AEAD-encrypted crosswalk + the key.

## Tech stack
- **R 4.5.x + Shiny + bslib + DT**; `openssl` + `sodium` for crypto; `sdcMicro` for disclosure
  control; `data.table`, `future`/`mirai` for parallel; `readxl`/`writexl`, `xml2`, `pdftools`,
  `tesseract`; `reticulate` for the optional Python NER/OCR engine.
- Reuses patterns from the author's **shinyEncrypt** (keyed hash/FPE/AEAD/signatures),
  **flexsynth** (linkage-risk metrics), **dicom_deid/AndyFishing** (portable R+reticulate).

## Project layout
```
app/
  app.R            Shiny UI + server (10 tabs incl. Documents: PDF/XML/ECG redaction)
  global.R         loads the core in order
  R/
    crypto.R       keyed HMAC pseudonyms, Feistel FPE, AEAD crosswalk, ed25519 signatures
    hashchain.R    tamper-evident append-only audit log
    identifiers.R  the 15-identifier catalogue + default actions (editable per project)
    detect_r.R     deterministic detectors + validators (NRIC/FIN checksum, phone, email, ...)
    profile.R      column profiling + misplaced-PII / outlier detection
    deidentify.R   transform engine (pseudonymize / fpe / generalize / redact / freetext)
    checkpoint.R   chunked/parallel/resumable de-id for large files (survives drive switch)
    sdc.R          statistical disclosure control (opt-in): k-anon, l-div, SUDA, risk, DCR, gate
    keystore.R     global vs project key material
    project.R      portable project folder, manifest (SHA-256), input registration
    engine_py.R    passive, air-gap-safe bridge to the bundled Python NER
    xml_scrub.R    XML de-id: generic + HL7 CDA/FHIR + Philips SierraECG + GE MUSE ECG
                   (scrub header PHI, preserve waveform payload; pure R via xml2)
    pdf_redact.R   PDF true redaction (digital + Tesseract OCR): rasterize + paint +
                   flatten to image-only PDF (removes text layer); pure R
  python/
    detect_ner.py  Presidio + spaCy NER (bundled model; no download)
samples/           synthetic test data + generator (make_sample.R) — NO real data
docs/roadmap.md    phased plan and status
run.ps1 / run.bat  portable launcher
```

## Conventions
- C#-style not applicable; **R** with `se_` prefix on all core functions, `snake_case`.
- Keep the core (`app/R/*.R`) pure and independently testable — every module has a headless test
  path (see the self-tests run during development). Prefer `testServer` for reactive logic.
- FPE is **optional**, not the default: IDs default to a keyed pseudonym token; choose FPE per
  field only when the downstream system needs the original shape preserved.
- Every SDC step is **opt-in**; export can be gated on k / max-risk thresholds.

## Build & run (dev)
- `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" -e "shiny::runApp('app', port=7788)"`
- Regenerate sample data: `Rscript samples/make_sample.R`

## Status / roadmap
Phases 0–1 complete and core proven end-to-end (crypto, detection, profiling, de-identify,
crosswalk re-id, manifest, hash-chained audit). See [docs/roadmap.md](docs/roadmap.md) for the
phase-by-phase plan (Python NER packaging, PDF/XML/ECG, full SDC UI, signed handoff, batch,
portable packaging).

## Repo note
The local clone's `origin` currently points at `R_slice_ar.git` (this folder was seeded from an
unrelated project). Confirm/point the remote at `structured_deidentification` before pushing.
