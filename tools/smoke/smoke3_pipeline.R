# Run from the repo root:  Rscript tools/smoke/smoke3_pipeline.R
# Scratch (projects, checkpoints, outputs) goes to a temp dir; override with SDS_SMOKE_DIR.
if (!file.exists("app/global.R")) stop("Run from the repo root (where app/ lives).")
suppressWarnings(suppressMessages(source("app/global.R")))
options(stringsAsFactors = FALSE)
options(se.app_r_dir = normalizePath("app/R"))
base <- Sys.getenv("SDS_SMOKE_DIR", unset = file.path(tempdir(), "sds_smoke3"))
unlink(base, recursive=TRUE); dir.create(base, recursive=TRUE)
tmp <- file.path(base, "tmp"); dir.create(tmp)

.pass <- 0L; .fail <- 0L; .rows <- c()
T <- function(name, expr) {
  ok <- FALSE; msg <- ""
  tryCatch({ v <- force(expr); ok <- isTRUE(v)
             if (!ok) msg <- paste("->", paste(utils::head(as.character(v),1), collapse=" ")) },
           error = function(e) msg <<- conditionMessage(e))
  if (ok) .pass <<- .pass + 1L else .fail <<- .fail + 1L
  .rows[[length(.rows)+1L]] <<- sprintf("  [%s] %s%s", if (ok) "PASS" else "FAIL", name,
                                        if (ok) "" else paste0("   -- ", msg))
}
sec <- function(s) .rows[[length(.rows)+1L]] <<- paste0("\n== ", s, " ==")

sec("PROJECT LIFECYCLE (project.R / keystore.R)")
pdir <- file.path(base, "proj")
proj <- se_project_create(pdir, "SmokeStudy", actor="alice", hash_scope="project")
T("project_create builds portable folder", dir.exists(pdir) && file.exists(se_project_paths(pdir)$json))
proj <- se_register_input(proj, "samples/sample_patients.csv", actor="alice")
pth <- se_project_paths(pdir)
T("register_input copies file + records SHA in manifest", {
  man <- jsonlite::fromJSON(pth$manifest); file.exists(file.path(pth$inputs,"sample_patients.csv")) &&
    any(grepl("sample_patients.csv", man$entries$file)) })
proj2 <- se_project_open(pdir)
T("project_open round-trips saved state", identical(proj2$name, "SmokeStudy") && identical(proj2$hash_scope,"project"))
key <- se_resolve_key(proj$hash_scope, proj)
T("project key resolves + is stable", { k2<-se_resolve_key(proj$hash_scope, proj); identical(as.raw(k2), as.raw(key)) })

sec("POLICY + CHECKPOINTED DE-IDENTIFY (deidentify.R / checkpoint.R)")
policy <- se_empty_policy()
policy$columns <- list(
  patient_name = list(action="pseudonymize", identifier="name"),
  nric         = list(action="fpe",          identifier="national_id"),
  dob          = list(action="generalize",   identifier="dob", options=list(generalize="year")),
  phone        = list(action="redact",        identifier="phone"),
  notes        = list(action="redact_freetext"))
policy$freetext_opts <- list(min_conf=0.5, use_pf=FALSE)
policy$freetext_columns <- c("notes")
proj$policy <- policy; proj <- se_project_save(proj)
inp <- file.path(pth$inputs, "sample_patients.csv")
r1 <- se_deidentify_file(proj, inp, policy, key, chunk_size = 8L)
T("chunked de-id splits into multiple chunks", r1$n_chunks > 1L && !isTRUE(r1$resumed))
T("de-id output written with all rows", file.exists(r1$output) && r1$nrec == 40L)
od <- read.csv(r1$output, colClasses="character")
T("output: phone redacted + dob year-only", all(od$phone=="[REDACTED]") && all(grepl("^[0-9]{4}$", od$dob[nzchar(od$dob)])))
sha1 <- se_sha256_file(r1$output)

sec("RESUME (mid-job) + PARALLEL")
r2 <- se_deidentify_file(proj, inp, policy, key, chunk_size = 8L)
T("re-run resumes (no recompute) + identical output", isTRUE(r2$resumed) && identical(se_sha256_file(r2$output), sha1))
slug <- se_file_slug(inp); cdir <- file.path(pth$work, slug)
chunks <- list.files(cdir, pattern="^chunk_[0-9]+\\.rds$", full.names=TRUE)
file.remove(chunks[[2]])                      # simulate an interrupted job (lost a chunk)
r3 <- se_deidentify_file(proj, inp, policy, key, chunk_size = 8L)
T("mid-job resume rebuilds only missing chunk -> identical output", identical(se_sha256_file(r3$output), sha1))
ppar <- se_project_create(file.path(base,"projP"), "Par", actor="alice", hash_scope="project")
ppar <- se_register_input(ppar, "samples/sample_patients.csv", actor="alice")
ppar$policy <- policy; se_project_save(ppar)
inpP <- file.path(se_project_paths(ppar$dir)$inputs, "sample_patients.csv")
rp <- tryCatch(se_deidentify_file(ppar, inpP, policy, key, chunk_size=8L, parallel=2L),
               error=function(e) e)
T("parallel workers produce complete output", !inherits(rp,"error") && file.exists(rp$output) && rp$nrec==40L)

sec("CROSSWALK PERSISTENCE + AUTHORIZED RE-ID")
saveRDS(se_crosswalk_encrypt(r1$crosswalk, key), pth$crosswalk)
T("crosswalk.enc persisted (AEAD)", file.exists(pth$crosswalk))
cwback <- se_crosswalk_decrypt(readRDS(pth$crosswalk), key)
subn <- cwback[cwback$column=="nric",]
df0 <- read.csv(inp, colClasses="character")
T("re-identify token -> original via decrypted crosswalk", identical(subn$original[match(od$nric[1], subn$token)], df0$nric[1]))

sec("MANIFEST + CERTIFICATE/REPORT (project.R / report.R)")
se_manifest_write(proj)
man <- jsonlite::fromJSON(pth$manifest)
T("manifest lists input + de-identified output with SHA-256", {
  any(man$entries$role=="input") && any(man$entries$role=="output") && all(nchar(man$entries$sha256)==64) })
cert <- se_cert_data(proj)
T("cert_data assembles policy + manifest + audit", is.list(cert) && is.data.frame(cert$policy_df) &&
  is.data.frame(cert$manifest_df) && isTRUE(cert$audit$ok))
pdf_cert <- file.path(tmp, "certificate.pdf")
se_report_pdf(cert, pdf_cert)
T("report_pdf renders a non-empty PDF (pure-R)", file.exists(pdf_cert) && file.info(pdf_cert)$size > 1000)

sec("AUDIT + SIGNED HANDOFF (hashchain.R / crypto.R)")
T("project audit chain verifies", isTRUE(se_audit_verify(pth$audit)$ok))
kp <- se_sig_keygen()
handoff <- list(manifest_sha = se_sha256_file(pth$manifest), stage="deidentified", by="alice")
sig <- se_sign(handoff, kp$secret)
T("de-identifier signs handoff; reviewer verifies", isTRUE(se_verify(handoff, sig, kp$public)))
T("tampered handoff fails verification", !isTRUE(se_verify(modifyList(handoff, list(by="mallory")), sig, kp$public)))

sec("BATCH RUNNER (batch.R) — mixed CSV + XML routing")
bsrc <- file.path(base, "batch_in"); dir.create(bsrc)
file.copy("samples/sample_patients.csv", file.path(bsrc,"sample_patients.csv"))
file.copy("samples/docs/philips_sierraecg.xml", file.path(bsrc,"philips_sierraecg.xml"))
file.copy("samples/docs/generic.xml", file.path(bsrc,"generic.xml"))
pb <- se_project_create(file.path(base,"projB"), "BatchStudy", actor="alice", hash_scope="project")
pb$policy <- policy; se_project_save(pb)
plan <- se_batch_plan(bsrc)
T("batch_plan routes by type (table + xml)", is.data.frame(plan) && "table" %in% plan$type && "xml" %in% plan$type)
res <- se_batch_run(pb, plan, opts=list(actor="alice"))
T("batch_run completes with no errors", res$totals$error==0 && res$totals$ok>=3)
pbp <- se_project_paths(pb$dir)
T("batch outputs written (csv + xml)", {
  file.exists(file.path(pbp$outputs,"sample_patients.deid.csv")) &&
  length(list.files(pbp$outputs, pattern="\\.xml$"))>=2 })
T("batch merged crosswalk persisted", file.exists(pbp$crosswalk))
T("batch audit chain verifies", isTRUE(se_audit_verify(pbp$audit)$ok))

sec("OFFLINE ENGINE — passive probe (engine_py.R)")
st <- se_py_status()
T("py_status returns passive status (no subprocess)", is.list(st) && "python" %in% names(st))
T("bundled python discovered on disk", isTRUE(st$python) || is.na(st$python) || is.character(st$python_path))
pf_probe <- se_pf_config()
T("pf_config passive (available reflects model presence)", is.list(pf_probe) && is.logical(pf_probe$available))

cat(paste(.rows, collapse="\n"), "\n")
cat(sprintf("\n==== SMOKE 3 (pipeline + batch + engine): %d PASS / %d FAIL ====\n", .pass, .fail))
if (.fail > 0) quit(status=1)
