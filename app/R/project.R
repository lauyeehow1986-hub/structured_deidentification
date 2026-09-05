# project.R — the self-contained, drive-portable project folder.
#
# Layout (everything travels together on the data drive):
#   project.json   settings, identifier policy, thresholds, per-file state
#   inputs/        registered source files
#   outputs/       de-identified files
#   work/          chunk checkpoints + per-file progress (resume/parallel)
#   keys/          project.key (project scope)
#   crosswalk.enc  AEAD-encrypted original<->token map (authorised re-id)
#   manifest.json  SHA-256 of every input & output
#   audit.log      hash-chained action log
#   signatures/    detached per-stage signatures
#   certificate.json  signed de-identification certificate

se_sha256_file <- function(path) {
  con <- file(path, open = "rb"); on.exit(close(con))
  paste0(openssl::sha256(con))   # paste0 drops the openssl class -> plain hex
}

se_project_paths <- function(dir) {
  list(
    dir       = dir,
    json      = file.path(dir, "project.json"),
    inputs    = file.path(dir, "inputs"),
    outputs   = file.path(dir, "outputs"),
    work      = file.path(dir, "work"),
    keys      = file.path(dir, "keys"),
    crosswalk = file.path(dir, "crosswalk.enc"),
    manifest  = file.path(dir, "manifest.json"),
    audit     = file.path(dir, "audit.log"),
    signatures= file.path(dir, "signatures"),
    certificate = file.path(dir, "certificate.json")
  )
}

se_project_create <- function(dir, name, actor = "unknown",
                              hash_scope = "project") {
  p <- se_project_paths(dir)
  for (d in c(p$dir, p$inputs, p$outputs, p$work, p$keys, p$signatures))
    dir.create(d, showWarnings = FALSE, recursive = TRUE)
  proj <- list(
    schema_version = 1L,
    name = name,
    created = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    created_by = actor,
    dir = dir,
    hash_scope = hash_scope,          # default scope for pseudonym/fpe
    identifiers = se_default_identifiers(),
    policy = se_empty_policy(),
    sdc = list(enabled = FALSE, steps = list(), thresholds =
                 list(k = 5L, max_risk = 0.05)),
    thresholds = list(k = 5L, max_risk = 0.05),
    files = list(),                   # per-file registration + state
    stage = "created",                # created->detected->deidentified->reviewed->signed
    signoff = list()
  )
  se_project_save(proj)
  se_audit_append(p$audit, "project_create", actor,
                  list(name = name, hash_scope = hash_scope))
  proj
}

se_project_open <- function(dir) {
  p <- se_project_paths(dir)
  if (!file.exists(p$json)) stop("no project.json in ", dir)
  proj <- jsonlite::fromJSON(p$json, simplifyVector = FALSE)
  proj$dir <- dir  # keep path current even if the drive letter changed
  proj
}

se_project_save <- function(proj) {
  p <- se_project_paths(proj$dir)
  proj$dir <- proj$dir
  jsonlite::write_json(proj, p$json, auto_unbox = TRUE, pretty = TRUE,
                       null = "null")
  invisible(proj)
}

#' Register an input file: copy into inputs/, checksum, add to manifest + state.
se_register_input <- function(proj, src_path, actor = "unknown") {
  p <- se_project_paths(proj$dir)
  base <- basename(src_path)
  dest <- file.path(p$inputs, base)
  if (normalizePath(src_path, mustWork = FALSE) != normalizePath(dest, mustWork = FALSE))
    file.copy(src_path, dest, overwrite = TRUE)
  sha <- se_sha256_file(dest)
  proj$files[[base]] <- list(name = base, role = "input", sha256 = sha,
                             registered = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
                             state = "registered")
  se_manifest_write(proj)
  se_project_save(proj)
  se_audit_append(p$audit, "import", actor, list(file = base, sha256 = sha))
  proj
}

se_manifest_write <- function(proj) {
  p <- se_project_paths(proj$dir)
  entries <- list()
  add_dir <- function(d, role) {
    if (!dir.exists(d)) return(invisible())
    for (f in list.files(d, full.names = TRUE)) {
      entries[[length(entries)+1L]] <<- list(
        file = file.path(basename(d), basename(f)), role = role,
        sha256 = se_sha256_file(f), bytes = file.info(f)$size)
    }
  }
  add_dir(p$inputs, "input"); add_dir(p$outputs, "output")
  man <- list(project = proj$name,
              generated = format(as.POSIXct(Sys.time(), tz="UTC"), "%Y-%m-%dT%H:%M:%SZ"),
              entries = entries)
  jsonlite::write_json(man, p$manifest, auto_unbox = TRUE, pretty = TRUE)
  invisible(man)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
