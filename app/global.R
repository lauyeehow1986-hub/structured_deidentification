# global.R — load the de-identification core. Sourced by app.R and by tests.
# Order matters: helpers (%||%) and low-level modules first.

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(DT)
})

se_source_dir <- function(dir) {
  files <- c("hashchain.R", "crypto.R", "identifiers.R", "detect_r.R",
             "profile.R", "deidentify.R", "xml_scrub.R", "pdf_redact.R",
             "keystore.R", "project.R", "checkpoint.R", "sdc.R",
             "sdc_transforms.R", "report.R", "engine_py.R")
  for (f in files) {
    fp <- file.path(dir, f)
    if (file.exists(fp)) sys.source(fp, envir = globalenv())
  }
  # Shiny modules (optional at core-test time)
  mod_dir <- file.path(dir, "modules")
  if (dir.exists(mod_dir))
    for (m in list.files(mod_dir, pattern = "\\.R$", full.names = TRUE))
      sys.source(m, envir = globalenv())
}

# Resolve the app/R directory relative to this file when run from the bundle.
.se_app_dir <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) "app")
if (is.null(.se_app_dir) || !nzchar(.se_app_dir)) .se_app_dir <- "app"
se_source_dir(file.path(.se_app_dir, "R"))

options(se.bundle_root = normalizePath(file.path(.se_app_dir, ".."),
                                       mustWork = FALSE))
# where parallel workers re-source the core from (see checkpoint.R)
options(se.app_r_dir = normalizePath(file.path(.se_app_dir, "R"),
                                     mustWork = FALSE))

# Bounded-memory Review/SDC for large outputs (see checkpoint.R readers):
#  * se.deid_inmem_max  — above this row count the finished output is NOT held
#    fully in memory; Review pages a window and SDC works off a sample.
#  * se.review_window_max — largest row window Review will read/show at once.
#  * se.sdc_sample_cap  — cap on rows sampled for SDC risk estimates.
options(se.deid_inmem_max   = getOption("se.deid_inmem_max",   200000L),
        se.review_window_max = getOption("se.review_window_max", 1000L),
        se.sdc_sample_cap   = getOption("se.sdc_sample_cap",    20000L))
