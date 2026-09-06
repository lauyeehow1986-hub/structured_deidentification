# app/R/batch.R — Phase 8 batch runner.
# Orchestrates the existing per-file pipelines over many inputs into one
# project's outputs / manifest / audit. Pure R, fail-soft, idempotent,
# optionally parallel. Adds NOTHING to detection/transform logic.

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a

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

# deterministic output path (idempotency key) for one planned item
se_batch_output_path <- function(p, path, type, out_format = "csv") {
  base <- tools::file_path_sans_ext(basename(path))
  if (type == "table") file.path(p$outputs, paste0(base, ".deid.", out_format))
  else if (type == "xml") file.path(p$outputs, paste0(base, ".deid.xml"))
  else if (type == "pdf") file.path(p$outputs, paste0(base, ".deid.pdf"))
  else NA_character_
}

# the batch run loop: fail-soft, idempotent, manifest/audit
se_batch_run <- function(proj, plan, opts = list(), progress = NULL) {
  stopifnot(is.data.frame(plan))
  p          <- se_project_paths(proj$dir)
  key        <- se_resolve_key(proj$hash_scope, proj)
  policy     <- proj$policy
  # batch-level free-text redaction controls (no interactive per-span review):
  # the confidence threshold + per-type policy do the gating; rejects stay empty.
  if (!is.null(opts$freetext_opts)) {
    fo <- opts$freetext_opts
    fo$rejects <- character(0)
    policy$freetext_opts <- fo
  }
  # optional interval-preserving date shift — DATE generalise columns only (leave
  # address/postal/age generalization untouched).
  if (isTRUE(opts$date_shift) && length(policy$columns)) {
    for (cn in names(policy$columns)) {
      spc <- policy$columns[[cn]]
      if (identical(spc$action, "generalize")) {
        cur <- spc$options$generalize %||% se_identifier(spc$identifier)$generalize
        if (isTRUE(cur %in% c("year", "year_month", "date_shift"))) {
          spc$options$generalize        <- "date_shift"
          spc$options$shift_window      <- as.integer(opts$shift_window %||% 365L)
          spc$options$shift_subject_col <- opts$shift_subject_col %||% ""
          policy$columns[[cn]] <- spc
        }
      }
    }
  }
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
        proj <- se_register_input(proj, path, actor = actor)
        se_xml_scrub_file(path, exp_out, key = key)
        rec$action <- "xml_scrub"; rec$output <- basename(exp_out)
      } else if (type == "pdf") {
        proj <- se_register_input(proj, path, actor = actor)
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
    if (file.exists(p$crosswalk)) {
      prior <- tryCatch(se_crosswalk_decrypt(readRDS(p$crosswalk), key),
                        error = function(e) NULL)
      if (!is.null(prior) && nrow(prior)) cw_frags <- c(list(prior), cw_frags)
    }
    cw <- se_merge_crosswalks(cw_frags)
    saveRDS(se_crosswalk_encrypt(cw, key), p$crosswalk)
  }
  se_manifest_write(proj); proj <- se_project_save(proj)

  rows <- lapply(items, function(r) data.frame(
    file = r$file, type = r$type, status = r$status,
    action = r$action %||% NA_character_, output = r$output %||% NA_character_,
    rows = r$rows %||% NA_integer_, elapsed = r$elapsed, detail = r$detail,
    stringsAsFactors = FALSE))
  df <- if (length(rows)) do.call(rbind, rows) else data.frame(
    file = character(), type = character(), status = character(),
    action = character(), output = character(), rows = integer(),
    elapsed = numeric(), detail = character(), stringsAsFactors = FALSE)
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

# summary writer (json + csv) for a batch run result
se_batch_write_summary <- function(result, dir = NULL) {
  dir <- dir %||% result$project$dir
  jf <- file.path(dir, "batch_summary.json"); cf <- file.path(dir, "batch_summary.csv")
  jsonlite::write_json(list(started = result$started, finished = result$finished,
                            totals = result$totals, items = result$items),
                       jf, auto_unbox = TRUE, pretty = TRUE)
  data.table::fwrite(result$items, cf, showProgress = FALSE)
  invisible(list(json = jf, csv = cf))
}
