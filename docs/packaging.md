# Packaging — the portable, MAX_PATH-safe bundle

The app ships as an **unzip-and-run** folder for a locked-down, air-gapped Windows
box. This doc covers how the bundle is built on a connected laptop, why it stays
under the Windows path limit when extracted into `Downloads`, and how to verify it
on the target.

> The **build** laptop may be online (it runs `install.packages` / pip). The
> **deployed** bundle makes **no network calls, ever** — everything it needs is
> inside it.

## What ships

```
sds/                      <- keep this folder name SHORT (see MAX_PATH below)
  app/                    Shiny UI + R core + Python engine sources
  bin/R/                  relocatable R 4.5.2 runtime + library (transitive closure)
  bin/python/  (optional) relocatable CPython + Presidio/spaCy NER  (-IncludePython)
  bin/llama/   (optional) llama.cpp exes            (-IncludeLlama; AV-sensitive)
  models/      (optional) *.gguf LLM weights        (-IncludeModels)
  docs/  samples/  tools/
  run.bat / run.ps1              double-click launcher (Shiny on 127.0.0.1)
  run_batch.bat / run_batch.ps1  headless batch runner
```

Tesseract, poppler and ImageMagick are **not** separate binaries — the R
`tesseract` / `pdftools` / `magick` packages bundle their own native libraries on
Windows. Only `tessdata/eng.traineddata` (inside the `tesseract` package) is needed
for OCR. So "portable R + (optional) Python" covers structured **and** document
de-identification.

`bin/llama/` is **excluded by default**: the unsigned `llama*.exe` are quarantined
by some AV (Defender/AVG/McAfee). The LLM second-opinion pass is opt-in and
sneakernetted separately; the bundle is complete without it.

## The MAX_PATH rule (why the bundle fits)

Windows' classic limit is **260 characters for an absolute path**, and a locked-down
box **cannot enable long-path support**. So the bundle must fit *by construction*
once extracted into `Downloads`.

Budget math for `C:\Users\<user>\Downloads\sds\` (≈ 44 chars for a 20-char user):

- The deepest files after build are Presidio's country recognizers, ≈ **134 chars
  relative** → ≈ **178 absolute** against the conservative audit root, and **163**
  against a real `C:\Users\lauye\Downloads\sds`. Comfortably under 255.
- The real hazard is the **R library**: `bin/R/library/RcppEigen/include/…` and
  `RcppArmadillo` headers run 200+ chars relative and would blow past 260.

Three build-time levers keep it safe — no registry changes, no long-path reliance:

1. **Short root.** Extract as `Downloads\sds`. Every saved character is headroom.
2. **Prune runtime-unneeded deep subtrees** from the R library:
   `include/  doc/  html/  help/  tests/  test/  examples/  po/`
   (keeps `libs/  R/  Meta/  data/  DESCRIPTION  NAMESPACE`). Dropping `include/`
   removes the Eigen/Armadillo header depth **and** shrinks the zip. Python
   `__pycache__/` and `*.pyc` are dropped too.
3. **Build-time auditor** (`tools/audit_pathlen.ps1`) computes the worst-case
   absolute length for every file against an assumed root and **fails the build**
   if anything exceeds budget (warn > 240, fail > 255).

Measured on this build: 17,283 files, R library of 177 packages, **longest
worst-case absolute = 163** at `Downloads\sds` (178 against the conservative
20-char-username root). Zip ≈ **667 MB** (R + Python, no LLM models).

## Build (on the connected laptop)

From the repo root:

```powershell
# 1) materialise a relocatable R under bin\R: runtime + the transitive closure of
#    the app's package deps (no compilation — copies already-installed packages).
powershell -File tools\stage_r.ps1

# 2) assemble -> prune -> audit -> closure-check -> zip. Builds to a SHORT external
#    root (default C:\sds_build) because assembling inside a deep worktree path can
#    itself hit MAX_PATH mid-build. Produces C:\sds_build\sds.zip.
powershell -File tools\build_bundle.ps1                 # R + Python (default)
#   -IncludeLlama  also ship bin\llama\ (AV-sensitive)
#   -IncludeModels also ship models\*.gguf
#   -Root  "C:\Users\<user>\Downloads\sds"   audit against a specific target root
```

`stage_r.ps1` copies the R runtime, then `tools/stage_r_deps.R` computes the
transitive closure of `Depends`/`Imports`/`LinkingTo` (excluding base + recommended
packages, which ride inside the runtime) and copies each into `bin\R\library`.

The build **fails closed** if the path audit or the dependency-closure check
(`tools/check_closure.ps1` — R DESCRIPTION deps + Python dist-info Requires-Dist)
finds a problem.

## Deploy + verify (on the target)

1. Copy `sds.zip` to the target's `Downloads`.
2. Extract with Windows 11's built-in **`tar.exe`** (handles long paths well) or
   File Explorer — **keep the folder short**: `C:\Users\<you>\Downloads\sds`.
   Do **not** rename it to something long or nest it deeper.
   ```powershell
   cd $env:USERPROFILE\Downloads
   tar.exe -xf sds.zip           # -> Downloads\sds
   ```
3. From inside the extracted folder, run the clean-machine verifier:
   ```powershell
   cd $env:USERPROFILE\Downloads\sds
   powershell -File tools\verify_clean_machine.ps1
   ```
   It (a) audits worst-case path length against the **actual** install root,
   (b) loads every critical R package from the bundle alone (it neutralises any
   per-user R library so the check is honest), and (c) runs a smoke batch de-id and
   asserts the tamper-evident audit chain verifies. Expect `VERIFY PASS`.
4. Launch: double-click **`run.bat`** (interactive app) or **`run_batch.bat`** with
   arguments (headless batch — see below).

## Batch runner

Both surfaces call the same pure-R engine (`app/R/batch.R`), routing each input by
type: CSV/XLSX → the chunked/resumable de-identify engine; PDF → true redaction;
XML/ECG → waveform-preserving scrub — all into one project's `outputs/`, merged
crosswalk, SHA-256 manifest, and hash-chained audit. It is **fail-soft** (a bad file
is recorded as an error, the run continues), **idempotent** (skips files already
output unless `--force`), and **parallel** (`--workers N`).

```powershell
run_batch.bat --project <projectDir> --inputs <folder|glob|;-list> `
              [--recursive] [--workers 4] [--out-format csv|xlsx] `
              [--actor NAME] [--force] [--strict]
```

Writes `batch_summary.json` + `batch_summary.csv` into the project. `--strict`
exits non-zero if any item errored. The interactive **Batch** tab exposes the same
engine (input folder, recurse, workers, force, per-item status table, summary
download).
