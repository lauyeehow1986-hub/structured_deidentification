# checkpoint.R — chunked, resumable, parallel de-identification for large files.
#
# se_deidentify_table (deidentify.R) transforms a whole data.frame in memory.
# For large extracts that is neither memory-safe nor restartable, so this module
# wraps it with:
#   * chunking      — process the file in row-slices of `chunk_size`.
#   * checkpoints   — each finished slice is written to work/<slug>/ as an .rds,
#                     with a progress.json recording what is done. A killed or
#                     power-lost run resumes from the first unfinished slice.
#   * parallel      — slices are independent (every transform is a pure function
#                     of value + key), so they fan out over future workers when
#                     asked; the fallback is plain sequential.
#   * portability   — every path is under the project folder, so unplugging the
#                     drive and reopening the project on another machine resumes
#                     exactly where it stopped (survives a drive-letter change).
#
# The engine stays pure (no Shiny, no audit writes) so it is headless-testable;
# the caller does the audit + manifest bookkeeping.
#
# Memory: CSV inputs with no embedded newlines are read one slice at a time
# (bounded memory). If quoting makes line offsets unreliable, or for XLSX, the
# file is read once and sliced in memory — correct, just not memory-bounded.

# --- small helpers -----------------------------------------------------------

se_file_slug <- function(name) {
  s <- gsub("[^A-Za-z0-9._-]+", "_", basename(name))
  s <- gsub("^_+|_+$", "", s)
  if (!nzchar(s)) s <- "table"
  s
}

.se_count_newlines <- function(path) {
  con <- file(path, open = "rb"); on.exit(close(con))
  n <- 0
  repeat {
    chunk <- readBin(con, what = "raw", n = 1048576L)
    if (!length(chunk)) break
    n <- n + sum(chunk == as.raw(10L))
  }
  n
}

.se_last_byte_is_newline <- function(path) {
  sz <- file.info(path)$size
  if (is.na(sz) || sz == 0) return(TRUE)
  con <- file(path, open = "rb"); on.exit(close(con))
  seek(con, where = sz - 1L, origin = "start")
  identical(readBin(con, what = "raw", n = 1L), as.raw(10L))
}

.se_digest_hex <- function(obj) {
  paste0(openssl::sha256(serialize(obj, connection = NULL)))
}

# --- reading the header + individual chunks ----------------------------------

se_table_header <- function(path, ext = tools::file_ext(path)) {
  ext <- tolower(ext)
  if (ext %in% c("xlsx", "xls")) {
    nm <- names(readxl::read_excel(path, n_max = 0L))
  } else {
    nm <- names(data.table::fread(path, nrows = 0L, showProgress = FALSE))
  }
  as.character(nm)
}

#' Read one row-slice of a CSV by line offset. Safe only when the file has no
#' embedded newlines (see se_plan_file, which decides).
se_read_csv_chunk <- function(path, header, start, n) {
  dt <- data.table::fread(path, skip = 1L + start, nrows = n, header = FALSE,
                          colClasses = "character", showProgress = FALSE,
                          blank.lines.skip = FALSE, na.strings = NULL)
  if (ncol(dt) && length(header))
    data.table::setnames(dt, header[seq_len(ncol(dt))])
  as.data.frame(dt, stringsAsFactors = FALSE)
}

# --- planning: how many rows, how to slice, is the fast path safe? -----------

#' Build the chunk plan for a file.
#' Returns: list(ext, header, nrec, chunk_size, mode, chunks, df_all)
#'   mode  = "lazy"  -> CSV slices read from disk on demand (bounded memory)
#'         = "whole" -> read once, slice in memory (XLSX, or unsafe-to-offset CSV)
#'   chunks= list of list(i, start (0-based), n)
se_plan_file <- function(path, chunk_size = 50000L) {
  ext <- tolower(tools::file_ext(path))
  header <- se_table_header(path, ext)
  df_all <- NULL

  if (ext %in% c("xlsx", "xls")) {
    df_all <- as.data.frame(readxl::read_excel(path, col_types = "text"),
                            stringsAsFactors = FALSE)
    nrec <- nrow(df_all); mode <- "whole"
  } else {
    # record-accurate row count (fread respects quoting)
    nrec <- nrow(data.table::fread(path, select = 1L, showProgress = FALSE,
                                   colClasses = "character", na.strings = NULL))
    # is line-offset slicing safe? (no records split across physical lines)
    nl <- .se_count_newlines(path)
    total_lines <- nl + (if (.se_last_byte_is_newline(path)) 0L else 1L)
    data_lines <- total_lines - 1L
    if (isTRUE(data_lines == nrec)) {
      mode <- "lazy"
    } else {
      # quoting made line offsets unreliable — fall back to a single correct read
      df_all <- as.data.frame(
        data.table::fread(path, colClasses = "character", showProgress = FALSE,
                          na.strings = NULL), stringsAsFactors = FALSE)
      nrec <- nrow(df_all); mode <- "whole"
    }
  }

  chunk_size <- max(1L, as.integer(chunk_size))
  chunks <- list()
  if (nrec == 0L) {
    chunks <- list(list(i = 1L, start = 0L, n = 0L))
  } else {
    starts <- seq.int(0L, nrec - 1L, by = chunk_size)
    for (k in seq_along(starts)) {
      st <- starts[k]
      chunks[[k]] <- list(i = k, start = st, n = min(chunk_size, nrec - st))
    }
  }
  list(ext = ext, header = header, nrec = nrec, chunk_size = chunk_size,
       mode = mode, chunks = chunks, df_all = df_all)
}

# --- progress file (the resume ledger) ---------------------------------------

se_progress_path <- function(chunk_dir) file.path(chunk_dir, "progress.json")

se_progress_read <- function(chunk_dir) {
  pp <- se_progress_path(chunk_dir)
  if (!file.exists(pp)) return(NULL)
  tryCatch(jsonlite::fromJSON(pp, simplifyVector = FALSE),
           error = function(e) NULL)
}

se_progress_write <- function(chunk_dir, prog) {
  jsonlite::write_json(prog, se_progress_path(chunk_dir),
                       auto_unbox = TRUE, pretty = TRUE)
  invisible(prog)
}

.se_chunk_data_path <- function(chunk_dir, i) file.path(chunk_dir, sprintf("chunk_%06d.rds", i))
.se_chunk_cw_path   <- function(chunk_dir, i) file.path(chunk_dir, sprintf("cw_%06d.rds", i))
.se_chunk_sum_path  <- function(chunk_dir, i) file.path(chunk_dir, sprintf("sum_%06d.rds", i))

# --- one chunk of work (runs in the worker, sequential or parallel) ----------

.se_process_chunk <- function(spec, path, header, mode, df_all,
                              policy, key, detectors, chunk_dir) {
  if (mode == "whole") {
    slice <- if (spec$n == 0L) df_all[0, , drop = FALSE]
             else df_all[(spec$start + 1L):(spec$start + spec$n), , drop = FALSE]
  } else {
    slice <- if (spec$n == 0L) {
      d <- se_read_csv_chunk(path, header, 0L, 1L); d[0, , drop = FALSE]
    } else se_read_csv_chunk(path, header, spec$start, spec$n)
  }
  res <- se_deidentify_table(slice, policy, key, detectors)
  saveRDS(res$data,      .se_chunk_data_path(chunk_dir, spec$i))
  saveRDS(res$crosswalk, .se_chunk_cw_path(chunk_dir, spec$i))
  saveRDS(res$summary,   .se_chunk_sum_path(chunk_dir, spec$i))
  list(i = spec$i, n = nrow(res$data))
}

# --- merge helpers -----------------------------------------------------------

se_merge_crosswalks <- function(frags) {
  frags <- Filter(function(x) !is.null(x) && nrow(x) > 0, frags)
  if (!length(frags)) return(data.frame(column = character(0), original = character(0),
                                        token = character(0), stringsAsFactors = FALSE))
  cw <- do.call(rbind, frags)
  key <- paste(cw$column, cw$original, sep = "\r")
  cw <- cw[!duplicated(key), , drop = FALSE]
  rownames(cw) <- NULL
  cw
}

.se_merge_summaries <- function(sums_list) {
  acc <- list()
  for (s in sums_list) for (col in names(s)) {
    if (is.null(acc[[col]])) acc[[col]] <- s[[col]]
    else acc[[col]]$n_changed <- acc[[col]]$n_changed + s[[col]]$n_changed
  }
  acc
}

# --- the orchestrator --------------------------------------------------------

#' De-identify one file with checkpoints, resume and optional parallelism.
#'
#' @param proj       open project (list); provides work/ + outputs/ paths.
#' @param path       input file path (usually under inputs/).
#' @param policy     column->action policy (see identifiers.R / deidentify.R).
#' @param key        resolved scope key (raw/character).
#' @param out_format "csv" or "xlsx".
#' @param chunk_size rows per slice.
#' @param parallel   FALSE, TRUE, or an integer worker count.
#' @param detectors  detector registry (free-text redaction).
#' @param app_r_dir  dir of app/R/*.R, so parallel workers can source the core.
#' @param progress_cb optional function(done, total) for UI progress.
#' @return list(output, crosswalk, summary, nrec, n_chunks, resumed, mode)
se_deidentify_file <- function(proj, path, policy, key, out_format = "csv",
                               chunk_size = 50000L, parallel = FALSE,
                               detectors = se_detectors(), app_r_dir = NULL,
                               progress_cb = NULL) {
  stopifnot(file.exists(path))
  p <- se_project_paths(proj$dir)
  slug <- se_file_slug(path)
  chunk_dir <- file.path(p$work, slug)
  dir.create(chunk_dir, showWarnings = FALSE, recursive = TRUE)

  plan <- se_plan_file(path, chunk_size)
  n_chunks <- length(plan$chunks)

  # signature ties the checkpoints to this exact input + policy + slicing.
  sig <- list(
    input_sha  = se_sha256_file(path),
    nrec       = plan$nrec,
    chunk_size = plan$chunk_size,
    n_chunks   = n_chunks,
    policy_hash = .se_digest_hex(policy),
    out_format = out_format)

  prev <- se_progress_read(chunk_dir)
  resumed <- FALSE
  if (!is.null(prev) && identical(prev$signature, sig)) {
    resumed <- TRUE                      # keep whatever chunk files exist
  } else {
    # stale or first run: clear old chunk artefacts
    old <- list.files(chunk_dir, pattern = "^(chunk|cw|sum)_[0-9]+\\.rds$",
                      full.names = TRUE)
    if (length(old)) file.remove(old)
  }

  # which chunks still need doing? (a chunk is done iff its data rds is present)
  done_flag <- vapply(seq_len(n_chunks),
                      function(i) file.exists(.se_chunk_data_path(chunk_dir, i)),
                      logical(1))
  pending <- plan$chunks[!done_flag]

  prog <- list(signature = sig, slug = slug, mode = plan$mode,
               total = n_chunks, done = sum(done_flag), stage = "running",
               updated = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
  se_progress_write(chunk_dir, prog)
  if (is.function(progress_cb)) progress_cb(prog$done, n_chunks)

  run_one <- function(spec) {
    .se_process_chunk(spec, path = path, header = plan$header, mode = plan$mode,
                      df_all = plan$df_all, policy = policy, key = key,
                      detectors = detectors, chunk_dir = chunk_dir)
  }

  want_parallel <- (isTRUE(parallel) || (is.numeric(parallel) && parallel > 1)) &&
                   length(pending) > 1L &&
                   requireNamespace("future.apply", quietly = TRUE)

  if (want_parallel) {
    workers <- if (is.numeric(parallel)) as.integer(parallel) else
               max(1L, future::availableCores() - 1L)
    rdir <- app_r_dir %||% getOption("se.app_r_dir",
              default = file.path(se_bundle_root(), "app", "R"))
    oldplan <- future::plan()
    on.exit(future::plan(oldplan), add = TRUE)
    future::plan(future::multisession, workers = workers)
    par_one <- function(spec) {
      # each worker is a fresh R process: source the core, then do the chunk.
      if (!exists("se_deidentify_table", mode = "function")) {
        for (f in list.files(rdir, pattern = "\\.R$", full.names = TRUE))
          sys.source(f, envir = globalenv())
      }
      .se_process_chunk(spec, path = path, header = plan$header, mode = plan$mode,
                        df_all = plan$df_all, policy = policy, key = key,
                        detectors = detectors, chunk_dir = chunk_dir)
    }
    future.apply::future_lapply(pending, par_one, future.seed = TRUE)
    prog$done <- n_chunks
    se_progress_write(chunk_dir, prog)
    if (is.function(progress_cb)) progress_cb(n_chunks, n_chunks)
  } else {
    for (spec in pending) {
      run_one(spec)
      prog$done <- prog$done + 1L
      prog$updated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
      se_progress_write(chunk_dir, prog)
      if (is.function(progress_cb)) progress_cb(prog$done, n_chunks)
    }
  }

  # ---- finalise: stitch chunk outputs into one file, in order ----
  base <- tools::file_path_sans_ext(basename(path))
  out  <- file.path(p$outputs, paste0(base, ".deid.", out_format))
  dir.create(dirname(out), showWarnings = FALSE, recursive = TRUE)

  if (out_format == "xlsx") {
    parts <- lapply(seq_len(n_chunks),
                    function(i) readRDS(.se_chunk_data_path(chunk_dir, i)))
    writexl::write_xlsx(do.call(rbind, parts), out)
  } else {
    if (file.exists(out)) file.remove(out)
    for (i in seq_len(n_chunks)) {
      part <- readRDS(.se_chunk_data_path(chunk_dir, i))
      data.table::fwrite(part, out, append = (i > 1L), col.names = (i == 1L),
                         showProgress = FALSE)
    }
  }

  cw <- se_merge_crosswalks(lapply(seq_len(n_chunks),
          function(i) readRDS(.se_chunk_cw_path(chunk_dir, i))))
  summ <- .se_merge_summaries(lapply(seq_len(n_chunks),
          function(i) readRDS(.se_chunk_sum_path(chunk_dir, i))))

  prog$stage <- "complete"; prog$output <- basename(out)
  prog$out_sha <- se_sha256_file(out)
  prog$updated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  se_progress_write(chunk_dir, prog)

  list(output = out, crosswalk = cw, summary = summ, nrec = plan$nrec,
       n_chunks = n_chunks, resumed = resumed, mode = plan$mode)
}

# --- bounded-memory reading of a finished output (Review + SDC) ---------------
#
# Processing is chunked/resumable, but Review and SDC used to pull the whole
# finished output into memory — exactly what the chunking set out to avoid. A
# reader gives two bounded ways back into a (possibly huge) table:
#   * se_read_window  — one contiguous row window (pagination for Review), and
#   * se_sample_table — a bounded, representative block sample (SDC risk).
# Over a lazy CSV a reader never holds more than the requested window/sample in
# memory; XLSX and quoted-newline CSV are read once (the engine's own limit).

#' Wrap an already-loaded data.frame as a reader (uniform API, no re-read).
se_reader_from_df <- function(df) {
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  list(path = NA_character_, format = "df", mode = "whole",
       header = names(df), nrec = nrow(df), df_all = df)
}

#' Open a read-only handle to a table file without loading it all (lazy CSV).
#' Reuses se_plan_file for ext/header/nrec/mode (and df_all in "whole" mode).
se_open_table <- function(path, format = NULL) {
  plan <- se_plan_file(path, chunk_size = .Machine$integer.max)
  list(path = path, format = format %||% plan$ext, mode = plan$mode,
       header = plan$header, nrec = plan$nrec, df_all = plan$df_all)
}

#' Empty (zero-row) frame carrying the reader's columns.
.se_reader_empty <- function(reader) {
  if (identical(reader$mode, "whole")) reader$df_all[0, , drop = FALSE]
  else se_read_csv_chunk(reader$path, reader$header, 0L, 1L)[0, , drop = FALSE]
}

#' Read a contiguous window: 1-based `start`, up to `n` rows. Bounded memory.
se_read_window <- function(reader, start = 1L, n = 1000L) {
  start <- max(1L, as.integer(start)); n <- max(0L, as.integer(n))
  if (n == 0L || reader$nrec == 0L || start > reader$nrec)
    return(.se_reader_empty(reader))
  hi <- min(reader$nrec, start + n - 1L); nn <- hi - start + 1L
  out <- if (identical(reader$mode, "whole"))
    reader$df_all[start:hi, , drop = FALSE]
  else
    se_read_csv_chunk(reader$path, reader$header, start - 1L, nn) # start-1 = 0-based
  rownames(out) <- NULL
  out
}

#' Read a set of contiguous blocks (list of list(start, n)) and stack them.
se_read_blocks <- function(reader, blocks) {
  if (!length(blocks)) return(.se_reader_empty(reader))
  parts <- lapply(blocks, function(b) se_read_window(reader, b$start, b$n))
  out <- do.call(rbind, parts); rownames(out) <- NULL; out
}

#' Pick block slots reproducibly without disturbing the caller's RNG stream.
.se_sample_slots <- function(n_slots, n_pick, seed) {
  if (exists(".Random.seed", envir = .GlobalEnv)) {
    old <- get(".Random.seed", envir = .GlobalEnv)
    on.exit(assign(".Random.seed", old, envir = .GlobalEnv), add = TRUE)
  } else {
    on.exit(if (exists(".Random.seed", envir = .GlobalEnv))
              rm(list = ".Random.seed", envir = .GlobalEnv), add = TRUE)
  }
  set.seed(seed)
  sample.int(n_slots, n_pick)
}

#' Bounded, representative sample of a reader for risk estimation.
#' Reads up to `max_rows` rows as a spread of disjoint `block`-sized slices, so
#' the memory cost is capped and a mirror reader can replay the same `blocks`
#' (row-aligned original vs de-identified, for DCR).
#' @return list(data, rows, blocks, sampled, nrec, n)
se_sample_table <- function(reader, max_rows = 20000L, block = 2000L, seed = 1L) {
  nrec <- reader$nrec; max_rows <- max(1L, as.integer(max_rows))
  if (nrec <= max_rows) {
    d <- se_read_window(reader, 1L, nrec)
    return(list(data = d, rows = if (nrec) seq_len(nrec) else integer(0),
                blocks = if (nrec) list(list(start = 1L, n = nrec)) else list(),
                sampled = FALSE, nrec = nrec, n = nrow(d)))
  }
  block   <- max(1L, min(as.integer(block), max_rows))
  n_slots <- nrec %/% block                       # full, disjoint block slots
  n_pick  <- min(n_slots, max(1L, max_rows %/% block))
  pick    <- sort(.se_sample_slots(n_slots, n_pick, seed))
  blocks  <- lapply(pick, function(s) list(start = (s - 1L) * block + 1L, n = block))
  rows    <- unlist(lapply(blocks, function(b) seq.int(b$start, b$start + b$n - 1L)))
  d       <- se_read_blocks(reader, blocks)
  list(data = d, rows = rows, blocks = blocks, sampled = TRUE, nrec = nrec, n = nrow(d))
}

#' Lightweight resume status for the UI (does not process anything).
se_deidentify_status <- function(proj, path, chunk_size = 50000L) {
  p <- se_project_paths(proj$dir)
  chunk_dir <- file.path(p$work, se_file_slug(path))
  prog <- se_progress_read(chunk_dir)
  if (is.null(prog)) return(list(exists = FALSE))
  done <- length(list.files(chunk_dir, pattern = "^chunk_[0-9]+\\.rds$"))
  list(exists = TRUE, stage = prog$stage %||% "running",
       done = done, total = prog$total %||% NA_integer_,
       output = prog$output %||% NA_character_, updated = prog$updated)
}
