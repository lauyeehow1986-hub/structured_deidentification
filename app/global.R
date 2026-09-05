# global.R — load the de-identification core. Sourced by app.R and by tests.
# Order matters: helpers (%||%) and low-level modules first.

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(DT)
})

se_source_dir <- function(dir) {
  files <- c("hashchain.R", "crypto.R", "identifiers.R", "detect_r.R",
             "profile.R", "deidentify.R", "keystore.R", "project.R",
             "checkpoint.R", "sdc.R", "engine_py.R")
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
