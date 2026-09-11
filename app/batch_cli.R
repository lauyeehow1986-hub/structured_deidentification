# app/batch_cli.R — headless batch runner.
# Usage: Rscript app/batch_cli.R --project <dir> --inputs <dir|glob> [--recursive]
#        [--workers N] [--out-format csv|xlsx] [--actor NAME] [--force] [--strict]
#        [--no-pf] [--ft-min-conf N] [--date-shift] [--shift-window N] [--shift-subject-col NAME]
#        [--gold <file>] [--apply-tunings]
# --gold ingests a ground-truth table (file,column,value,identifier) after the run,
#   writing per-identifier recall + tuning suggestions into batch_summary.json.
# --apply-tunings applies those suggestions headless (requires an explicit --actor).
suppressWarnings(suppressMessages(source("app/global.R", local = FALSE)))

args <- commandArgs(trailingOnly = TRUE)
getflag <- function(k) k %in% args
getopt  <- function(k, d = NULL) { i <- match(k, args); if (is.na(i) || i == length(args)) d else args[i + 1L] }

proj_dir <- getopt("--project"); inputs <- getopt("--inputs")
if (is.null(proj_dir) || is.null(inputs)) stop("--project and --inputs are required")
proj <- if (file.exists(file.path(proj_dir, "project.json"))) {
  se_project_open(proj_dir)
} else {
  se_project_create(proj_dir, getopt("--name", basename(proj_dir)),
                     actor = getopt("--actor", "batch"))
}

plan <- se_batch_plan(strsplit(inputs, ";")[[1]], recursive = getflag("--recursive"))
cat(sprintf("Planned %d file(s): %s\n", nrow(plan),
            paste(table(plan$type), names(table(plan$type)), collapse=", ")))
res <- se_batch_run(proj, plan, opts = list(
  actor = getopt("--actor", "batch"),
  workers = as.integer(getopt("--workers", "1")),
  out_format = getopt("--out-format", "csv"),
  force = getflag("--force"),
  freetext_opts = list(use_pf = !getflag("--no-pf"),
                       min_conf = as.numeric(getopt("--ft-min-conf", "0.5")),
                       types = NULL, rejects = character(0)),
  date_shift = getflag("--date-shift"),
  shift_window = as.integer(getopt("--shift-window", "365")),
  shift_subject_col = getopt("--shift-subject-col", "")),
  progress = function(i, n, f) cat(sprintf("[%d/%d] %s\n", i, n, f)))
se_batch_write_summary(res)
print(res$items[, c("file","type","status","action","output","rows","elapsed")])
cat(sprintf("\nDone: %d ok, %d error, %d skipped in %.1fs\n",
            res$totals$ok, res$totals$error, res$totals$skipped, res$totals$seconds))

# --- Phase 9: optional ground-truth ingest + headless apply -----------------
gold_path <- getopt("--gold")
if (!is.null(gold_path) && nzchar(gold_path) && file.exists(gold_path)) {
  actor <- getopt("--actor", "batch")
  gold  <- utils::read.csv(gold_path, stringsAsFactors = FALSE,
                           colClasses = "character")
  ing   <- se_autotune_ingest_gold(proj, gold, inputs = plan, actor = actor)
  sug   <- se_autotune_suggest(proj)
  sfile <- file.path(proj_dir, "batch_summary.json")
  summ  <- if (file.exists(sfile)) jsonlite::fromJSON(sfile, simplifyVector = FALSE)
           else list()
  summ$autotune <- list(recall = ing$recall, missed = ing$missed,
                        suggestions = sug)
  jsonlite::write_json(summ, sfile, auto_unbox = TRUE, pretty = TRUE)
  cat(sprintf("Gold ingest: %d missed; %d suggestion(s).\n",
              ing$missed, nrow(sug)))
  if (getflag("--apply-tunings")) {
    if (is.null(getopt("--actor")))
      stop("--apply-tunings requires an explicit --actor")
    proj <- se_autotune_apply(proj, sug, actor = actor)
    cat(sprintf("Applied %d tuning(s); policy version now %d.\n",
                nrow(sug), proj$policy$version))
  }
}

if (getflag("--strict") && res$totals$error > 0L) quit(status = 1L)
quit(status = 0L)
