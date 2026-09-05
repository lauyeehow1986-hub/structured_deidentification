# hashchain.R — tamper-evident, append-only audit log.
#
# Each entry is one line of JSON. Every entry carries `prev_hash` (the SHA-256
# of the previous entry's canonical form) so any insertion, deletion or edit
# anywhere in the file breaks the chain from that point on. The log is written
# next to the project (audit.log) and is verifiable on the air-gapped target
# with nothing but this file.

.se_entry_canon <- function(entry) {
  # Deterministic serialisation of the fields that are hashed (everything
  # except the entry's own `hash`).
  fields <- entry[setdiff(names(entry), "hash")]
  jsonlite::toJSON(fields, auto_unbox = TRUE, null = "null", digits = NA)
}

se_hash_entry <- function(entry) {
  paste0(openssl::sha256(charToRaw(as.character(.se_entry_canon(entry)))))
}

#' Return the hash of the last entry in a log file, or the genesis constant.
se_audit_tip <- function(log_path) {
  if (!file.exists(log_path)) return("GENESIS")
  lines <- readLines(log_path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  if (!length(lines)) return("GENESIS")
  last <- jsonlite::fromJSON(lines[length(lines)], simplifyVector = TRUE)
  last$hash
}

#' Append one action to the audit log.
#'
#' @param log_path path to audit.log
#' @param action   short verb, e.g. "import", "detect", "deidentify", "signoff"
#' @param actor    user id / role acting
#' @param detail   named list of extra fields (files, counts, checksums, ...)
se_audit_append <- function(log_path, action, actor, detail = list()) {
  dir.create(dirname(log_path), showWarnings = FALSE, recursive = TRUE)
  prev <- se_audit_tip(log_path)
  entry <- list(
    ts = format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%OS3Z"),
    action = action,
    actor = actor,
    detail = detail,
    prev_hash = prev
  )
  entry$hash <- se_hash_entry(entry)
  cat(jsonlite::toJSON(entry, auto_unbox = TRUE, null = "null", digits = NA),
      "\n", file = log_path, append = TRUE, sep = "")
  invisible(entry)
}

#' Verify the whole chain. Returns list(ok=logical, broken_at=index|NA, n=count).
se_audit_verify <- function(log_path) {
  if (!file.exists(log_path)) return(list(ok = TRUE, broken_at = NA_integer_, n = 0L))
  lines <- readLines(log_path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  prev <- "GENESIS"
  for (i in seq_along(lines)) {
    e <- jsonlite::fromJSON(lines[i], simplifyVector = TRUE)
    # rebuild without $hash and recompute
    stored_hash <- e$hash
    e$hash <- NULL
    if (!identical(e$prev_hash, prev)) return(list(ok = FALSE, broken_at = i, n = length(lines)))
    if (!identical(se_hash_entry(e), stored_hash)) return(list(ok = FALSE, broken_at = i, n = length(lines)))
    prev <- stored_hash
  }
  list(ok = TRUE, broken_at = NA_integer_, n = length(lines))
}

#' Read the log into a data.frame for display.
se_audit_read <- function(log_path) {
  if (!file.exists(log_path)) return(data.frame())
  lines <- readLines(log_path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  if (!length(lines)) return(data.frame())
  rows <- lapply(lines, function(l) {
    e <- jsonlite::fromJSON(l, simplifyVector = TRUE)
    data.frame(
      ts = e$ts %||% NA, action = e$action %||% NA, actor = e$actor %||% NA,
      detail = jsonlite::toJSON(e$detail, auto_unbox = TRUE),
      hash = substr(e$hash, 1, 12),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
