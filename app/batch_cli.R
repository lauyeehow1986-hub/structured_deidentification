# app/batch_cli.R — headless batch runner.
# Usage: Rscript app/batch_cli.R --project <dir> --inputs <dir|glob> [--recursive]
#        [--workers N] [--out-format csv|xlsx] [--actor NAME] [--force] [--strict]
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
  force = getflag("--force")),
  progress = function(i, n, f) cat(sprintf("[%d/%d] %s\n", i, n, f)))
se_batch_write_summary(res)
print(res$items[, c("file","type","status","action","output","rows","elapsed")])
cat(sprintf("\nDone: %d ok, %d error, %d skipped in %.1fs\n",
            res$totals$ok, res$totals$error, res$totals$skipped, res$totals$seconds))
if (getflag("--strict") && res$totals$error > 0L) quit(status = 1L)
quit(status = 0L)
