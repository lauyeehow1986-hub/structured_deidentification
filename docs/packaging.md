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

1. Copy the zip to the target's `Downloads`.
2. Extract it and **keep the folder short** — `C:\Users\<you>\Downloads\sds`
   (the LLM bundle extracts to `sds_full`, which is still safe; rename it to
   `sds` if you like). Do **not** nest it deeper or give it a long name.
   - **Recommended — File Explorer:** right-click the zip -> **Extract All...**
     The Windows shell handles these Zip64 archives (including the >4 GB LLM
     bundle) with no admin rights.
   - **Scripted (locked-down-safe), handles Zip64 / >4 GB:**
     ```powershell
     Add-Type -AssemblyName System.IO.Compression.FileSystem
     [System.IO.Compression.ZipFile]::ExtractToDirectory(
       "$env:USERPROFILE\Downloads\sds.zip", "$env:USERPROFILE\Downloads")
     ```
   - **Do NOT use `tar.exe -xf`** on these bundles. The zip is produced by .NET
     `ZipFile` (native Zip64); Windows' bundled **bsdtar misreads it** ("this
     does not look like a tar archive") and extracts nothing. `Expand-Archive`
     (PowerShell 5.1) can also choke on the >4 GB LLM bundle. Use Explorer or the
     .NET call above.
   - **Antivirus note:** some AV (AVG / Defender) quarantines `bin\R\bin\x64\
     Rscript.exe` (and the unsigned `bin\llama\*.exe`) when it lands in certain
     folders — extracting under your **user profile** (`Downloads`) avoids this on
     the tested machine. If R won't start, confirm `bin\R\bin\x64\Rscript.exe`
     still exists and restore it / add an AV exclusion for the bundle folder.
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
