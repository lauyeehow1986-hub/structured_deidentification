# Phase 8 — Batch Runner + MAX_PATH-Safe Packaging — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fail-soft, idempotent, optionally-parallel batch runner over many files (tables + PDF/XML) and a MAX_PATH-safe portable-bundle build/verify toolchain, then produce and verify a real `sds.zip`.

**Architecture:** A pure-R `batch.R` engine orchestrates the *existing* Phase 3 (`se_deidentify_file`) and Phase 7 (`se_pdf_redact` / `se_xml_scrub_file`) pipelines into one project's outputs/manifest/audit. A CLI (`app/batch_cli.R` + `run_batch.ps1`) and a Batch Shiny tab both call the engine. PowerShell `tools/` scripts stage a relocatable R, prune deep runtime-unneeded subtrees, audit worst-case path length against an assumed `Downloads\sds` root, check dependency closure, build the zip, and verify a fresh extraction.

**Tech Stack:** R 4.5.2 + Shiny/bslib/DT; `future.apply`; base `grDevices`; PowerShell 5.1; `tar.exe` (Win11).

---

## Project conventions that override the skill defaults

- **The repo commits NO tests.** All self-tests are written under the **scratchpad**
  `C:\Users\lauye\AppData\Local\Temp\claude\C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932\8ccd5522-a88b-42ac-8439-bd1a6ff18933\scratchpad`
  and run from there. "Commit" steps stage **source + docs only**.
- **Run R via a script file**, never `Rscript -e` multiline (segfaults on this box):
  `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" <scriptfile.R>`.
- **ASK before committing/pushing.** Do the final commit (Task 12) only after the user says go.
- Never stage `.claude/`. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- `se_` prefix, `snake_case`; core stays pure/testable.

## File structure

- Create `app/R/batch.R` — batch engine (`se_batch_type`, `se_batch_plan`,
  `se_batch_output_path`, `se_batch_run`, `se_batch_write_summary`).
- Modify `app/global.R` — source `batch.R`.
- Create `app/batch_cli.R` — headless CLI entry (arg parse → run).
- Create `run_batch.ps1`, `run_batch.bat` — CLI launchers.
- Modify `app/app.R` — add the Batch `nav_panel` + server wiring.
- Create `tools/audit_pathlen.ps1`, `tools/check_closure.ps1`, `tools/stage_r.ps1`,
  `tools/build_bundle.ps1`, `tools/verify_clean_machine.ps1`.
- Create `docs/packaging.md`; modify `docs/roadmap.md`, `CLAUDE.md`.
- Scratchpad only (not committed): `test_batch.R`, `test_batch_tab.R`.

---

## Task 1: Batch classify + plan

**Files:** Create `app/R/batch.R`; Test: scratchpad `test_batch.R`.

- [ ] **Step 1: Write the failing test** (scratchpad `test_batch.R`, first block)

```r
WT <- "C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932"
R  <- file.path(WT, "app", "R")
for (f in c("keystore.R","crypto.R","hashchain.R","identifiers.R","detect_r.R",
            "deidentify.R","project.R","checkpoint.R","xml_scrub.R","pdf_redact.R","batch.R"))
  sys.source(file.path(R, f), envir = globalenv())
fails <- 0L
ok <- function(c,m){cat(if(isTRUE(c))"  PASS "else"  FAIL ",m,"\n"); if(!isTRUE(c)) fails<<-fails+1L}

d <- file.path(tempdir(), paste0("bp_", as.integer(runif(1,1,1e6)))); dir.create(d)
write.csv(data.frame(nric="S1234567D"), file.path(d,"a.csv"), row.names=FALSE)
writeLines("<x/>", file.path(d,"b.xml")); writeLines("%PDF-1.4", file.path(d,"c.pdf"))
writeLines("hi", file.path(d,"d.txt"))
pl <- se_batch_plan(d)
ok(nrow(pl)==4L, "plan finds 4 files")
ok(pl$type[pl$file=="a.csv" | basename(pl$path)=="a.csv"]=="table", "csv -> table")
ok(se_batch_type("x.PDF")=="pdf" && se_batch_type("x.XML")=="xml", "ext case-insensitive")
ok(se_batch_type("x.txt")=="skip", "unknown -> skip")
```

- [ ] **Step 2: Run to verify it fails** — `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" <scratch>\test_batch.R` → FAIL (`se_batch_plan` not found).

- [ ] **Step 3: Implement** (create `app/R/batch.R` with the header + these functions)

```r
# app/R/batch.R — Phase 8 batch runner.
# Orchestrates the existing per-file pipelines over many inputs into one
# project's outputs / manifest / audit. Pure R, fail-soft, idempotent,
# optionally parallel. Adds NOTHING to detection/transform logic.

if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a

# classify one path by extension -> pipeline type
se_batch_type <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("csv", "xlsx", "xls")) "table"
  else if (ext == "pdf") "pdf"
  else if (ext == "xml") "xml"
  else "skip"
}

# inputs: a directory, a glob, and/or an explicit vector of file paths
se_batch_plan <- function(inputs, recursive = FALSE) {
  paths <- character(0)
  for (it in inputs) {
    if (dir.exists(it)) {
      paths <- c(paths, list.files(it, full.names = TRUE, recursive = recursive))
    } else if (grepl("[*?]", it)) {
      paths <- c(paths, Sys.glob(it))
    } else {
      paths <- c(paths, it)
    }
  }
  paths <- unique(paths[file.exists(paths) & !dir.exists(paths)])
  if (!length(paths))
    return(data.frame(path = character(), file = character(),
                      type = character(), stringsAsFactors = FALSE))
  data.frame(path = paths, file = basename(paths),
             type = vapply(paths, se_batch_type, character(1)),
             stringsAsFactors = FALSE, row.names = NULL)
}
```

- [ ] **Step 4: Run to verify it passes** — same command → the four Task-1 checks PASS.

## Task 2: Deterministic output path (idempotency key)

**Files:** Modify `app/R/batch.R`; Test: scratchpad `test_batch.R`.

- [ ] **Step 1: Add test block**

```r
p <- se_project_paths(file.path(tempdir(),"proj"))  # paths only; dir need not exist
ok(basename(se_batch_output_path(p,"z/a.csv","table","csv"))=="a.deid.csv", "table out name")
ok(basename(se_batch_output_path(p,"z/b.xml","xml","csv"))=="b.deid.xml",  "xml out name")
ok(basename(se_batch_output_path(p,"z/c.pdf","pdf","csv"))=="c.deid.pdf",  "pdf out name")
```

- [ ] **Step 2: Run → FAIL** (`se_batch_output_path` not found).

- [ ] **Step 3: Implement** (append to `app/R/batch.R`) — mirrors the naming that
  `se_deidentify_file` (`base.deid.<fmt>`) and the Documents tab (`.deid.<ext>`) already use:

```r
se_batch_output_path <- function(paths, path, type, out_format = "csv") {
  base <- tools::file_path_sans_ext(basename(path))
  if (type == "table") file.path(paths$outputs, paste0(base, ".deid.", out_format))
  else if (type == "xml") file.path(paths$outputs, paste0(base, ".deid.xml"))
  else if (type == "pdf") file.path(paths$outputs, paste0(base, ".deid.pdf"))
  else NA_character_
}
```

- [ ] **Step 4: Run → PASS.**

## Task 3: The batch run loop (fail-soft, idempotent, manifest/audit)

**Files:** Modify `app/R/batch.R`; Test: scratchpad `test_batch.R`.

- [ ] **Step 1: Add test block** (real project, mixed inputs, a deliberately broken file)

```r
tmp <- file.path(tempdir(), paste0("br_", as.integer(runif(1,1,1e6))))
proj <- se_project_create(tmp, "Batch Cohort", actor="alice", hash_scope="project")
proj$policy$columns <- list(nric=list(identifier="nric", action="pseudonymize"))
se_project_save(proj)
din <- file.path(tmp,"drop"); dir.create(din)
write.csv(data.frame(nric=c("S1234567D","S7654321J")), file.path(din,"t1.csv"), row.names=FALSE)
write.csv(data.frame(nric=c("G9876543K")),            file.path(din,"t2.csv"), row.names=FALSE)
source(file.path(WT,"samples","make_xml_samples.R"), local=TRUE)  # writes fixtures? if not, inline one
writeLines('<ClinicalDocument xmlns="urn:hl7-org:v3"><recordTarget><patientRole><id extension="S1234567D"/></patientRole></recordTarget></ClinicalDocument>',
           file.path(din,"doc.xml"))
writeLines("not,a,valid\nxlsx", file.path(din,"bad.xlsx"))  # forces a per-item error

pl  <- se_batch_plan(din)
res <- se_batch_run(proj, pl, opts=list(actor="alice", workers=1L))
ok(res$totals$n == nrow(pl), "all items attempted")
ok(res$totals$ok >= 3L, "csv x2 + xml ok")
ok(res$totals$error >= 1L, "bad xlsx recorded as error, not a crash")
ok(file.exists(file.path(se_project_paths(tmp)$outputs,"t1.deid.csv")), "t1 output written")
ok(file.exists(se_project_paths(tmp)$crosswalk), "merged crosswalk written")
ao <- se_audit_read(se_project_paths(tmp)$audit)
ok("batch_run" %in% ao$action && "batch_item" %in% ao$action, "audit actions logged")
# idempotent re-run: everything already produced -> skipped
res2 <- se_batch_run(proj, pl, opts=list(actor="alice"))
ok(res2$totals$skipped >= 3L, "re-run skips completed items")
```

- [ ] **Step 2: Run → FAIL** (`se_batch_run` not found).

- [ ] **Step 3: Implement** (append to `app/R/batch.R`)

```r
se_batch_run <- function(proj, plan, opts = list(), progress = NULL) {
  stopifnot(is.data.frame(plan))
  p          <- se_project_paths(proj$dir)
  key        <- se_resolve_key(proj$hash_scope, proj)
  policy     <- proj$policy
  detectors  <- se_detectors()
  workers    <- as.integer(opts$workers %||% 1L)
  force      <- isTRUE(opts$force)
  out_format <- opts$out_format %||% "csv"
  actor      <- opts$actor %||% "batch"
  chunk_size <- as.integer(opts$chunk_size %||% 50000L)

  items <- vector("list", nrow(plan)); cw_frags <- list(); t0 <- Sys.time()
  for (i in seq_len(nrow(plan))) {
    path <- plan$path[i]; type <- plan$type[i]
    if (is.function(progress)) progress(i, nrow(plan), basename(path))
    started <- Sys.time()
    rec <- list(file = basename(path), path = path, type = type, status = "ok",
                action = NA_character_, output = NA_character_, rows = NA_integer_,
                detail = "", elapsed = 0)

    exp_out <- se_batch_output_path(p, path, type, out_format)
    if (!force && !is.na(exp_out) && file.exists(exp_out)) {
      rec$status <- "skipped"; rec$output <- basename(exp_out)
      rec$detail <- "output exists (opts$force to redo)"; items[[i]] <- rec; next
    }

    ok_item <- tryCatch({
      if (type == "table") {
        proj <- se_register_input(proj, path, actor = actor)
        r <- se_deidentify_file(proj, path, policy, key, out_format = out_format,
               chunk_size = chunk_size,
               parallel = if (workers > 1L) workers else FALSE,
               detectors = detectors, app_r_dir = getOption("se.app_r_dir"))
        cw_frags[[length(cw_frags) + 1L]] <- r$crosswalk
        rec$action <- "deidentify"; rec$output <- basename(r$output); rec$rows <- r$nrec
        rec$detail <- sprintf("%d chunks%s", r$n_chunks,
                              if (isTRUE(r$resumed)) ", resumed" else "")
      } else if (type == "xml") {
        se_xml_scrub_file(path, exp_out, key = key)
        rec$action <- "xml_scrub"; rec$output <- basename(exp_out)
      } else if (type == "pdf") {
        se_pdf_redact(path, exp_out, dpi = as.integer(opts$dpi %||% 150L),
                      force_ocr = isTRUE(opts$force_ocr))
        rec$action <- "pdf_redact"; rec$output <- basename(exp_out)
      } else {
        rec$status <- "skipped"; rec$detail <- "unsupported type"
      }
      TRUE
    }, error = function(e) { rec$status <<- "error"; rec$detail <<- conditionMessage(e); FALSE })

    rec$elapsed <- round(as.numeric(difftime(Sys.time(), started, units = "secs")), 2)
    if (identical(rec$status, "ok") && !is.na(rec$action))
      se_audit_append(p$audit, "batch_item", actor,
                      list(file = rec$file, action = rec$action, output = rec$output))
    items[[i]] <- rec
  }

  if (length(cw_frags)) {
    cw   <- se_merge_crosswalks(cw_frags)
    saveRDS(se_crosswalk_encrypt(cw, key), p$crosswalk)
  }
  se_manifest_write(proj); proj <- se_project_save(proj)

  df <- do.call(rbind, lapply(items, function(r) data.frame(
    file = r$file, type = r$type, status = r$status,
    action = r$action %||% NA_character_, output = r$output %||% NA_character_,
    rows = r$rows %||% NA_integer_, elapsed = r$elapsed, detail = r$detail,
    stringsAsFactors = FALSE)))
  totals <- list(n = nrow(df), ok = sum(df$status == "ok"),
                 error = sum(df$status == "error"), skipped = sum(df$status == "skipped"),
                 seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 2))
  se_audit_append(p$audit, "batch_run", actor,
                  list(n = totals$n, ok = totals$ok, error = totals$error,
                       skipped = totals$skipped))
  list(items = df, totals = totals, project = proj,
       started = format(t0, "%Y-%m-%dT%H:%M:%S"),
       finished = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
}
```

- [ ] **Step 4: Run → PASS** (all Task-3 checks green; the bad `.xlsx` is an `error` row, not a crash).

## Task 4: Summary writer + parallel==sequential check

**Files:** Modify `app/R/batch.R`; Test: scratchpad `test_batch.R`.

- [ ] **Step 1: Add test block**

```r
sm <- se_batch_write_summary(res)
ok(file.exists(sm$json) && file.exists(sm$csv), "summary json+csv written")
# parallel path equals sequential on outputs (two fresh projects, same inputs)
mk <- function() { tp<-file.path(tempdir(),paste0("bp_",as.integer(runif(1,1,1e6))))
  pr<-se_project_create(tp,"P",actor="a",hash_scope="project")
  pr$policy$columns<-list(nric=list(identifier="nric",action="pseudonymize")); se_project_save(pr); pr }
d2<-file.path(tempdir(),paste0("d2_",as.integer(runif(1,1,1e6)))); dir.create(d2)
for(k in 1:3) write.csv(data.frame(nric=sprintf("S%07dD",k)), file.path(d2,paste0("f",k,".csv")), row.names=FALSE)
rs<-se_batch_run(mk(), se_batch_plan(d2), opts=list(workers=1L))
rp<-se_batch_run(mk(), se_batch_plan(d2), opts=list(workers=2L))
ok(identical(sort(rs$items$output), sort(rp$items$output)), "parallel == sequential outputs")
```

- [ ] **Step 2: Run → FAIL** (`se_batch_write_summary` not found).

- [ ] **Step 3: Implement** (append to `app/R/batch.R`)

```r
se_batch_write_summary <- function(result, dir = NULL) {
  dir <- dir %||% result$project$dir
  jf <- file.path(dir, "batch_summary.json"); cf <- file.path(dir, "batch_summary.csv")
  jsonlite::write_json(list(started = result$started, finished = result$finished,
                            totals = result$totals, items = result$items),
                       jf, auto_unbox = TRUE, pretty = TRUE)
  data.table::fwrite(result$items, cf, showProgress = FALSE)
  invisible(list(json = jf, csv = cf))
}
```

- [ ] **Step 4: Run → PASS.** End the scratchpad file with the pass/fail summary + `quit(status=...)`.

## Task 5: Source batch.R in global.R

**Files:** Modify `app/global.R`.

- [ ] **Step 1:** Read the source-order vector in `app/global.R` and add `"batch.R"` after `"pdf_redact.R"` (or after `"checkpoint.R"`; it must load after the pipelines it calls).

```r
# ...,"xml_scrub.R", "pdf_redact.R", "batch.R", "report.R", "engine_py.R")
```

- [ ] **Step 2: Verify** — run scratchpad `test_batch.R` again through `app/global.R` sourcing (or re-run standalone) → still PASS.

## Task 6: Headless CLI — `app/batch_cli.R` + `run_batch.ps1`/`.bat`

**Files:** Create `app/batch_cli.R`, `run_batch.ps1`, `run_batch.bat`.

- [ ] **Step 1: Create `app/batch_cli.R`** (base-R arg parse; a committed script file, never `-e`)

```r
# app/batch_cli.R — headless batch runner.
# Usage: Rscript app/batch_cli.R --project <dir> --inputs <dir|glob> [--recursive]
#        [--workers N] [--out-format csv|xlsx] [--actor NAME] [--force] [--strict]
suppressWarnings(suppressMessages(source("app/global.R", local = FALSE)))

args <- commandArgs(trailingOnly = TRUE)
getflag <- function(k) k %in% args
getopt  <- function(k, d = NULL) { i <- match(k, args); if (is.na(i) || i == length(args)) d else args[i + 1L] }

proj_dir <- getopt("--project"); inputs <- getopt("--inputs")
if (is.null(proj_dir) || is.null(inputs)) stop("--project and --inputs are required")
proj <- if (file.exists(file.path(proj_dir, "project.json"))) se_project_open(proj_dir)
        else se_project_create(proj_dir, getopt("--name", basename(proj_dir)),
                               actor = getopt("--actor", "batch"))

plan <- se_batch_plan(strsplit(inputs, ";")[[1]], recursive = getflag("--recursive"))
cat(sprintf("Planned %d file(s): %s\n", nrow(plan),
            paste(table(plan$type), names(table(plan$type)), collapse=", ")))
res <- se_batch_run(proj, plan, opts = list(
  actor = getopt("--actor", "batch"),
  workers = as.integer(getopt("--workers", "1")),
  out_format = getopt("--out-format", "csv"),
  force = getflag("--force")),
  progress = function(i, n, f) cat(sprintf("[%d/%d] %s\n", i, n, f)))
se_batch_write_summary(res)
print(res$items[, c("file","type","status","action","output","rows","elapsed")])
cat(sprintf("\nDone: %d ok, %d error, %d skipped in %.1fs\n",
            res$totals$ok, res$totals$error, res$totals$skipped, res$totals$seconds))
if (getflag("--strict") && res$totals$error > 0L) quit(status = 1L)
quit(status = 0L)
```

- [ ] **Step 2: Create `run_batch.ps1`** (reuses the R-finder pattern from `run.ps1`)

```powershell
# run_batch.ps1 — headless batch launcher. Args pass through to app/batch_cli.R.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Find-Rscript {
  $b = Join-Path $root "bin\R\bin\Rscript.exe"; if (Test-Path $b) { return $b }
  $g = Get-ChildItem (Join-Path $root "bin\R") -Recurse -Filter Rscript.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($g) { return $g.FullName }
  $s = Get-ChildItem "C:\Program Files\R" -Directory -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -like "R-*" } | Sort-Object Name -Descending | Select-Object -First 1
  if ($s) { $rs = Join-Path $s.FullName "bin\Rscript.exe"; if (Test-Path $rs) { return $rs } }
  throw "No R found. Bundle R under bin\R or install R 4.5+."
}
$py = Join-Path $root "bin\python\python.exe"; if (Test-Path $py) { $env:SE_PYTHON = $py }
Set-Location $root
& (Find-Rscript) "app\batch_cli.R" @args
exit $LASTEXITCODE
```

- [ ] **Step 3: Create `run_batch.bat`**

```bat
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_batch.ps1" %*
```

- [ ] **Step 4: Verify live** — make a temp project + drop folder, then:
  `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" app\batch_cli.R --project <tmp> --inputs <drop> --actor alice`
  from the worktree root → prints the plan, per-file lines, a status table, and `batch_summary.*` in the project dir. Fix any arg-parse issues.

## Task 7: Batch Shiny tab

**Files:** Modify `app/app.R`; Test: scratchpad `test_batch_tab.R`.

- [ ] **Step 1: Add UI `nav_panel`** after the Documents panel:

```r
  nav_panel("Batch", icon = icon("layer-group"),
    h4("Batch de-identification"),
    p(class="small text-muted", "Runs the same pipelines as the single-file tabs ",
      "over many inputs into this project's outputs, manifest, and audit trail. ",
      "Tables use the current column policy; PDF/XML use the Documents pipeline."),
    textInput("batch_dir", "Input folder (or ;-separated paths)"),
    checkboxInput("batch_recursive", "Recurse into subfolders", FALSE),
    numericInput("batch_workers", "Parallel workers", 1, min = 1, max = 8),
    checkboxInput("batch_force", "Redo files that already have output", FALSE),
    actionButton("btn_batch", "Run batch", class = "btn-primary"),
    br(), br(),
    DToutput("batch_tbl"),
    downloadButton("dl_batch_summary", "Download batch summary (CSV)")),
```

- [ ] **Step 2: Add server wiring** (near the Documents observers)

```r
  observeEvent(input$btn_batch, {
    req(rv$proj); p <- se_project_paths(rv$proj$dir)
    plan <- se_batch_plan(strsplit(input$batch_dir %||% "", ";")[[1]],
                          recursive = isTRUE(input$batch_recursive))
    if (!nrow(plan)) { showNotification("No files found.", type="warning"); return() }
    withProgress(message = "Running batch...", value = 0, {
      res <- se_batch_run(rv$proj, plan,
        opts = list(actor = input$actor, workers = as.integer(input$batch_workers %||% 1L),
                    force = isTRUE(input$batch_force)),
        progress = function(i, n, f) setProgress(value = i/n, detail = sprintf("%d/%d %s", i, n, f)))
      se_batch_write_summary(res); rv$proj <- res$project; rv$batch <- res
    })
    showNotification(sprintf("Batch: %d ok, %d error, %d skipped.",
      res$totals$ok, res$totals$error, res$totals$skipped), type="message")
  })
  output$batch_tbl <- renderDT({ req(rv$batch); DT::datatable(rv$batch$items, options=list(pageLength=15)) })
  output$dl_batch_summary <- downloadHandler(
    filename = function() paste0(rv$proj$name %||% "project", "_batch_summary.csv"),
    content  = function(file) data.table::fwrite(rv$batch$items, file))
```

- [ ] **Step 3:** Add `batch = NULL` to the `reactiveValues(...)` block.

- [ ] **Step 4: Write + run `test_batch_tab.R`** (scratchpad) — `testServer(server, {...})`: set `rv$proj`, `input$actor`, `input$batch_dir`; fire `btn_batch`; assert `rv$batch$totals$ok >= 1`, `output$batch_tbl` renders, `output$dl_batch_summary` writes a CSV, and a `batch_run` audit action exists. → PASS.

## Task 8: Path-length auditor — `tools/audit_pathlen.ps1`

**Files:** Create `tools/audit_pathlen.ps1`.

- [ ] **Step 1: Implement**

```powershell
# tools/audit_pathlen.ps1 — worst-case MAX_PATH audit for a bundle tree.
# Computes len(assumedRoot) + 1 + len(relativePath) for every file and flags any
# over budget. Default root models extraction into a user's Downloads as 'sds'.
param(
  [string]$Path = ".",
  [string]$Root = "C:\Users\a_twenty_char_userxx\Downloads\sds",  # conservative
  [int]$Warn = 240,
  [int]$Max  = 255,
  [int]$Top  = 15
)
$base = (Resolve-Path $Path).Path
$rootLen = $Root.TrimEnd('\').Length + 1
$items = Get-ChildItem -LiteralPath $base -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($base.Length).TrimStart('\')
  [pscustomobject]@{ Abs = $rootLen + $rel.Length; Rel = $rel }
}
$sorted = $items | Sort-Object Abs -Descending
$maxAbs = ($sorted | Select-Object -First 1).Abs
Write-Host ("Assumed root: {0}  (len {1})" -f $Root, $rootLen)
Write-Host ("Files: {0}   Longest absolute: {1}   Budget: warn>{2} fail>{3}" -f $items.Count, $maxAbs, $Warn, $Max)
Write-Host "`nTop $Top longest (worst-case absolute):"
$sorted | Select-Object -First $Top | ForEach-Object { "{0,4}  {1}" -f $_.Abs, $_.Rel }
$over = $sorted | Where-Object { $_.Abs -gt $Max }
$warn = $sorted | Where-Object { $_.Abs -gt $Warn -and $_.Abs -le $Max }
if ($warn) { Write-Host ("`nWARN: {0} file(s) between {1} and {2}." -f $warn.Count, $Warn, $Max) -ForegroundColor Yellow }
if ($over) { Write-Host ("`nFAIL: {0} file(s) exceed {1}." -f $over.Count, $Max) -ForegroundColor Red; exit 1 }
Write-Host "`nPASS: all paths within budget." -ForegroundColor Green; exit 0
```

- [ ] **Step 2: Verify live** — run against the staged tree and against a temp tree
  containing a deliberately long relative path (e.g. create nested dirs summing >220 chars)
  to confirm it prints FAIL and `exit 1`:
  `powershell -File tools\audit_pathlen.ps1 -Path bin\python` (PASS) and a synthetic
  over-budget dir (FAIL). Fix formatting if needed.

## Task 9: Dependency-closure checker — `tools/check_closure.ps1`

**Files:** Create `tools/check_closure.ps1`.

- [ ] **Step 1: Implement**

```powershell
# tools/check_closure.ps1 — verify the bundle's dependency closure.
# R: every package's DESCRIPTION Imports/Depends/LinkingTo present in bin\R\library.
# Python: every dist-info METADATA Requires-Dist present in site-packages.
param([string]$Bundle = ".")
$fail = 0
$rlib = Join-Path $Bundle "bin\R\library"
if (Test-Path $rlib) {
  $have = (Get-ChildItem $rlib -Directory).Name
  $base = @("base","compiler","datasets","graphics","grDevices","grid","methods",
            "parallel","splines","stats","stats4","tcltk","tools","utils","R")
  foreach ($pkg in Get-ChildItem $rlib -Directory) {
    $desc = Join-Path $pkg.FullName "DESCRIPTION"; if (!(Test-Path $desc)) { continue }
    $txt = (Get-Content $desc -Raw)
    foreach ($field in "Depends","Imports","LinkingTo") {
      if ($txt -match "(?ms)^$field\s*:\s*(.+?)(^\S|\z)") {
        ($matches[1] -split ",") | ForEach-Object {
          $dep = ($_ -replace "\(.*?\)","").Trim() -replace "\s.*",""
          if ($dep -and $dep -notin $base -and $dep -notin $have) {
            Write-Host ("R MISSING: {0} needs {1}" -f $pkg.Name, $dep) -ForegroundColor Red; $script:fail++ }
        }
      }
    }
  }
} else { Write-Host "No bin\R\library (R not staged yet) — skipping R closure." -ForegroundColor Yellow }

$site = Join-Path $Bundle "bin\python\Lib\site-packages"
if (Test-Path $site) {
  $have = (Get-ChildItem $site -Directory -Filter *.dist-info | ForEach-Object {
             ($_.Name -replace "-\d.*$","") .ToLower() -replace "_","-" })
  foreach ($di in Get-ChildItem $site -Directory -Filter *.dist-info) {
    $md = Join-Path $di.FullName "METADATA"; if (!(Test-Path $md)) { continue }
    Get-Content $md | Where-Object { $_ -like "Requires-Dist:*" } | ForEach-Object {
      $line = $_ -replace "^Requires-Dist:\s*",""
      if ($line -match ";\s*extra") { return }           # optional extras: skip
      $dep = ($line -split "[ <>=;\(\[]")[0].ToLower() -replace "_","-"
      if ($dep -and $dep -notin $have) {
        Write-Host ("PY  MISSING: {0} -> {1}" -f $di.Name, $dep) -ForegroundColor Red; $script:fail++ }
    }
  }
} else { Write-Host "No bin\python site-packages — skipping Python closure." -ForegroundColor Yellow }

if ($fail) { Write-Host ("`nFAIL: {0} missing dependency(ies)." -f $fail) -ForegroundColor Red; exit 1 }
Write-Host "`nPASS: dependency closure satisfied." -ForegroundColor Green; exit 0
```

- [ ] **Step 2: Verify live** — `powershell -File tools\check_closure.ps1 -Bundle .`
  against the current tree (Python present, R skipped). Review the missing list; it must be
  empty for the bundled Python. Note any false positives from extras and refine the skip.

## Task 10: R staging + bundle build — `tools/stage_r.ps1`, `tools/build_bundle.ps1`

**Files:** Create `tools/stage_r.ps1`, `tools/build_bundle.ps1`.

- [ ] **Step 1: Create `tools/stage_r.ps1`** (connected build laptop; materialises `bin\R`)

```powershell
# tools/stage_r.ps1 — make a relocatable R under bin\R with the exact deps.
# Run on the CONNECTED build laptop. Copies the R runtime, then installs the
# dependency set into bin\R\library from CRAN.
param(
  [string]$RHome = "C:\Program Files\R\R-4.5.2",
  [string]$Dest  = "bin\R",
  [string]$Repo  = "https://cloud.r-project.org"
)
$ErrorActionPreference = "Stop"
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
Copy-Item $RHome $Dest -Recurse
$lib = Join-Path $Dest "library"
$pkgs = @("shiny","bslib","DT","jsonlite","openssl","sodium","data.table",
          "future","future.apply","readxl","writexl","xml2","pdftools",
          "tesseract","magick","sdcMicro","digest","htmltools","later","mirai")
$rs = Join-Path $Dest "bin\Rscript.exe"
$expr = "install.packages(commandArgs(TRUE), lib='$($lib -replace '\\','/')', repos='$Repo')"
& $rs -e $expr @pkgs                       # short one-liner is safe; long scripts are not
Write-Host "Staged R + $($pkgs.Count) packages into $lib" -ForegroundColor Green
```

- [ ] **Step 2: Create `tools/build_bundle.ps1`** (assemble → prune → audit → closure → zip)

```powershell
# tools/build_bundle.ps1 — assemble the MAX_PATH-safe portable zip.
param(
  [string]$Out = "dist",
  [string]$Name = "sds",
  [switch]$IncludePython = $true,
  [switch]$IncludeLlama  = $false,
  [string]$Root = "C:\Users\a_twenty_char_userxx\Downloads\sds"
)
$ErrorActionPreference = "Stop"
$stage = Join-Path $Out $Name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# 1) app code + launchers + docs + samples + licenses
foreach ($d in "app","docs","samples") { Copy-Item $d (Join-Path $stage $d) -Recurse }
foreach ($f in "run.bat","run.ps1","run_batch.bat","run_batch.ps1","README.md","CLAUDE.md") {
  if (Test-Path $f) { Copy-Item $f $stage } }

# 2) runtimes
if (Test-Path "bin\R") { Copy-Item "bin\R" (Join-Path $stage "bin\R") -Recurse }
if ($IncludePython -and (Test-Path "bin\python")) { Copy-Item "bin\python" (Join-Path $stage "bin\python") -Recurse }
if ($IncludeLlama  -and (Test-Path "bin\llama"))  { Copy-Item "bin\llama"  (Join-Path $stage "bin\llama")  -Recurse }
if (Test-Path "models") { Copy-Item "models" (Join-Path $stage "models") -Recurse }

# 3) prune runtime-unneeded deep subtrees (kills the boost/Eigen depth + shrinks size)
$prune = @("include","doc","html","help","tests","test","examples","po")
foreach ($p in $prune) {
  Get-ChildItem $stage -Recurse -Directory -Filter $p -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\bin\\R\\library\\" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Get-ChildItem $stage -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Get-ChildItem $stage -Recurse -File -Include *.pyc -ErrorAction SilentlyContinue | Remove-Item -Force
# app scratch/state must never ship
foreach ($junk in "inputs","outputs","work") {
  Get-ChildItem $stage -Recurse -Directory -Filter $junk -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }

# 4) audit + closure (fail the build on violation)
& powershell -NoProfile -File "tools\audit_pathlen.ps1" -Path $stage -Root $Root
if ($LASTEXITCODE -ne 0) { throw "MAX_PATH audit failed — prune more or shorten the root." }
& powershell -NoProfile -File "tools\check_closure.ps1" -Bundle $stage
if ($LASTEXITCODE -ne 0) { throw "Dependency closure failed — stage the missing packages." }

# 5) zip (tar.exe handles long paths + is on Win11)
$zip = Join-Path $Out ("$Name.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
tar.exe -a -c -f $zip -C $Out $Name
Write-Host "Built $zip" -ForegroundColor Green
```

- [ ] **Step 3: Run `stage_r.ps1`** — `powershell -File tools\stage_r.ps1` (heavy: sdcMicro
  compiles). Confirm `bin\R\library` populated.

- [ ] **Step 4: Run `build_bundle.ps1`** — `powershell -File tools\build_bundle.ps1`.
  Expect: prune runs, audit PASS (this is the proof the bundled-R tree stays under 260 after
  pruning), closure PASS, `dist\sds.zip` produced. If audit FAILS, extend the prune list or
  document a shorter root, then re-run.

## Task 11: Clean-machine verifier — `tools/verify_clean_machine.ps1`

**Files:** Create `tools/verify_clean_machine.ps1`.

- [ ] **Step 1: Implement**

```powershell
# tools/verify_clean_machine.ps1 — run ON the target after extracting sds.zip.
# Verifies path budget, R packages load, Python probe, and a smoke de-id whose
# audit chain verifies. Emits PASS/FAIL.
param([string]$Bundle = ".")
$ErrorActionPreference = "Stop"; $fail = 0
& powershell -NoProfile -File (Join-Path $Bundle "tools\audit_pathlen.ps1") -Path $Bundle -Root ((Resolve-Path $Bundle).Path)
if ($LASTEXITCODE -ne 0) { $fail++ }
$rs = Join-Path $Bundle "bin\R\bin\Rscript.exe"
if (!(Test-Path $rs)) { $rs = (Get-ChildItem (Join-Path $Bundle "bin\R") -Recurse -Filter Rscript.exe | Select-Object -First 1).FullName }
$smoke = Join-Path $env:TEMP "sds_smoke.R"
@'
suppressWarnings(suppressMessages(source("app/global.R", local=FALSE)))
for (p in c("shiny","DT","openssl","sodium","data.table","xml2","pdftools","tesseract","sdcMicro"))
  stopifnot(requireNamespace(p, quietly=TRUE))
tmp <- file.path(tempdir(),"sds_v"); unlink(tmp,recursive=TRUE)
proj <- se_project_create(tmp,"verify",actor="v",hash_scope="project")
proj$policy$columns <- list(nric=list(identifier="nric",action="pseudonymize")); se_project_save(proj)
d <- file.path(tmp,"in"); dir.create(d)
write.csv(data.frame(nric=c("S1234567D","S7654321J")), file.path(d,"s.csv"), row.names=FALSE)
res <- se_batch_run(proj, se_batch_plan(d), opts=list(actor="v"))
p <- se_project_paths(tmp)
stopifnot(res$totals$ok==1L, file.exists(file.path(p$outputs,"s.deid.csv")), isTRUE(se_audit_verify(p$audit)$ok))
cat("SMOKE OK\n")
'@ | Set-Content -Encoding UTF8 $smoke
Push-Location $Bundle; & $rs $smoke; $code = $LASTEXITCODE; Pop-Location
if ($code -ne 0) { $fail++; Write-Host "Smoke de-id FAILED" -ForegroundColor Red }
if ($fail) { Write-Host "`nVERIFY FAIL ($fail)" -ForegroundColor Red; exit 1 }
Write-Host "`nVERIFY PASS" -ForegroundColor Green; exit 0
```

- [ ] **Step 2: Verify live** — extract `dist\sds.zip` to a realistic path
  (`C:\Users\lauye\Downloads\sds`) and run `powershell -File tools\verify_clean_machine.ps1`
  from inside it. Expect audit PASS + `SMOKE OK` + `VERIFY PASS`. This is the local proxy for
  the operator's clean-machine run.

## Task 12: Docs + roadmap + CLAUDE.md, then commit (GATED)

**Files:** Create `docs/packaging.md`; modify `docs/roadmap.md`, `CLAUDE.md`.

- [ ] **Step 1: Write `docs/packaging.md`** — bundle layout; `stage_r` → `build_bundle`
  steps; the prune list; MAX_PATH budget math + extraction guidance (prefer Win11
  `tar.exe -xf sds.zip`, keep root short e.g. `Downloads\sds`, don't rename deeper); and the
  clean-machine checklist mapping to `verify_clean_machine.ps1`.

- [ ] **Step 2: Update `docs/roadmap.md`** — mark Phase 8 ✅ with the batch engine, CLI, tab,
  `tools/` toolchain, and the MAX_PATH strategy; correct "portable R + Python + Tesseract" to
  note Tesseract rides inside the R packages.

- [ ] **Step 3: Update `CLAUDE.md`** — add `batch.R` to the `R/` layout, and a short
  `tools/` + `run_batch.*` note.

- [ ] **Step 4: Self-review** the scratchpad suites ran green; `git status` shows only intended
  files; `bin/ models/ dist/` are git-ignored (confirm with `git status --porcelain`).

- [ ] **Step 5: ASK the user to commit.** On approval, stage source+docs only (NOT `.claude/`,
  NOT `bin/ models/ dist/`, NOT scratchpad tests) and commit:

```bash
git add app/R/batch.R app/batch_cli.R app/global.R app/app.R \
        run_batch.ps1 run_batch.bat tools/ docs/ CLAUDE.md
git commit -m "$(cat <<'EOF'
Phase 8: batch runner + MAX_PATH-safe portable packaging

Batch engine (app/R/batch.R) routes tables/PDF/XML through the existing
pipelines into one project (fail-soft, idempotent, parallel); CLI
(app/batch_cli.R + run_batch.*) and a Batch tab drive it. tools/ stages a
relocatable R, prunes deep subtrees, audits worst-case path length against a
Downloads\sds root, checks dependency closure, builds sds.zip, and verifies a
fresh extraction. Docs + roadmap updated.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6:** Update memory (`project_structured_deid.md` + `MEMORY.md`) with Phase 8 done.

---

## Self-review (against the spec)

- **Batch surface (core+CLI+tab):** Tasks 1–7. ✓
- **Batch scope (tables + PDF/XML):** Task 3 routes all three. ✓
- **Ollama LLM pass:** backend pre-exists; batch passes `opts$use_llm/llm_backend` through the
  same detection path (documented; no new detection code — as the spec states). ✓
- **MAX_PATH: short root / prune / auditor:** Tasks 8, 10 (prune + audit gate). ✓
- **Closure check:** Task 9. ✓
- **Real bundle build + verify:** Tasks 10–11. ✓
- **Docs/roadmap/CLAUDE.md + Tesseract wording fix:** Task 12. ✓
- **No committed tests; scratchpad only; ASK-before-commit:** conventions section + Task 12. ✓
