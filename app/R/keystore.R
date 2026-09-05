# keystore.R — key material for the two hashing scopes.
#
#   global  : one 32-byte key shared across all projects, kept OUTSIDE any
#             project folder (default <bundle>/keys/global.key). Same person ->
#             same token across projects, enabling cross-project linkage.
#   project : a 32-byte key generated per project, stored with the project
#             (default <project>/keys/project.key) OR, for stronger custody, on
#             a separate drive path recorded in project.json.
#
# Keys never enter the audit log or the outputs. The crosswalk is encrypted
# under a key derived from the relevant scope key (see crypto.R).

se_bundle_root <- function() {
  # directory that contains app/ ; resolved from this file's location at source()
  getOption("se.bundle_root", default = normalizePath(".", mustWork = FALSE))
}

se_global_keystore_path <- function() {
  getOption("se.global_key_path",
            default = file.path(se_bundle_root(), "keys", "global.key"))
}

.se_read_or_make_key <- function(path, size = 32L) {
  if (file.exists(path)) {
    k <- readBin(path, what = "raw", n = size)
    if (length(k) == size) return(k)
  }
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  k <- sodium::random(size)
  writeBin(k, path)
  k
}

se_get_global_key <- function() {
  .se_read_or_make_key(se_global_keystore_path())
}

se_get_project_key <- function(proj) {
  path <- proj$project_key_path %||% file.path(proj$dir, "keys", "project.key")
  .se_read_or_make_key(path)
}

#' Resolve the raw key for a scope. `scope` is "global" or "project".
se_resolve_key <- function(scope, proj = NULL) {
  if (identical(scope, "global")) return(se_get_global_key())
  if (identical(scope, "project")) {
    if (is.null(proj)) stop("project scope needs a project")
    return(se_get_project_key(proj))
  }
  stop("unknown key scope: ", scope)
}
