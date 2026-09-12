# Run from the repo root:  Rscript tools/smoke/smoke1_core.R
if (!file.exists("app/global.R")) stop("Run from the repo root (where app/ lives).")
suppressWarnings(suppressMessages(source("app/global.R")))
options(stringsAsFactors = FALSE)
tmp <- file.path(tempdir(), paste0("smoke1_", as.integer(runif(1,1,1e6)))); dir.create(tmp)

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

df0 <- read.csv("samples/sample_patients.csv", colClasses = "character")
k1 <- "master-key-alpha"; k2 <- "master-key-bravo"

sec("CRYPTO (crypto.R / keystore.R)")
T("pseudonymize deterministic", identical(se_pseudonymize("S1234567D", k1), se_pseudonymize("S1234567D", k1)))
T("pseudonymize key isolation (project vs project)", se_pseudonymize("S1234567D", k1) != se_pseudonymize("S1234567D", k2))
T("pseudonymize cross-project linkage (same global key)", identical(se_pseudonymize("PATIENT-X", k1, salt="link"), se_pseudonymize("PATIENT-X", k1, salt="link")))
T("pseudonymize NA/blank -> NA", is.na(se_pseudonymize(NA, k1)) && is.na(se_pseudonymize("  ", k1)))
enc <- se_fpe("S1234567D", k1, mode="alnum_upper", tweak="natid")
T("FPE preserves shape + changes value", nchar(enc)==nchar("S1234567D") && enc != "S1234567D")
T("FPE reversible round-trip", identical(se_fpe(enc, k1, mode="alnum_upper", tweak="natid", decrypt=TRUE), "S1234567D"))
T("FPE digits mode round-trip", { e<-se_fpe("91234567", k1, mode="digits"); identical(se_fpe(e,k1,mode="digits",decrypt=TRUE),"91234567") && grepl("^[0-9]{8}$", e) })
cwdf <- data.frame(column="nric", original=c("A","B"), token=c("X","Y"))
T("AEAD crosswalk encrypt/decrypt round-trip", identical(se_crosswalk_decrypt(se_crosswalk_encrypt(cwdf,k1),k1), cwdf))
T("AEAD crosswalk wrong key fails", inherits(tryCatch(se_crosswalk_decrypt(se_crosswalk_encrypt(cwdf,k1),k2), error=function(e)e),"error"))
blob <- se_blob_encrypt(list(records=list(1,2,3)), k1, "feedback")
T("AEAD blob (feedback store) round-trip", identical(se_blob_decrypt(blob,k1,"feedback"), list(records=list(1,2,3))))
T("AEAD blob wrong label fails", inherits(tryCatch(se_blob_decrypt(blob,k1,"watchlist"),error=function(e)e),"error"))
kp <- se_sig_keygen(); obj <- list(stage="deid", who="alice", ts=123)
sg <- se_sign(obj, kp$secret)
T("ed25519 sign + verify", isTRUE(se_verify(obj, sg, kp$public)))
T("ed25519 rejects tampered object", !isTRUE(se_verify(list(stage="deid",who="mallory",ts=123), sg, kp$public)))
T("ed25519 rejects wrong public key", !isTRUE(se_verify(obj, sg, se_sig_keygen()$public)))

sec("DETECTORS + VALIDATORS (detect_r.R)")
T("NRIC checksum: exactly one valid check-letter", sum(vapply(LETTERS, function(L) se_nric_valid(paste0(substr(df0$nric[2],1,8),L)), logical(1)))==1L)
T("NRIC valid on sample value", se_nric_valid(df0$nric[2]))
T("Luhn valid/invalid (16-digit card)", isTRUE(se_luhn("4539148803436467")) && !isTRUE(se_luhn("4539148803436460")))
det <- se_detectors()
s <- paste0("NRIC ", df0$nric[2], " ph 91234567 mail kin.tan@example.com dob 15/06/1948 postal 520123")
sp <- se_scan_text(s, det)
T("scan_text finds multiple identifier types", length(unique(sp$detector)) >= 4)
T("scan_text catches email", any(sp$type=="email"))
T("scan_text catches valid NRIC", any(grepl(df0$nric[2], sp$match)))
cv <- se_classify_value(df0$nric[2])
T("classify_value tags NRIC", "nric" %in% names(cv))
T("dedup_overlaps returns non-growing frame", { d<-se_dedup_overlaps(sp); is.data.frame(d) && nrow(d)<=nrow(sp) })
wl <- se_watchlist_detector(data.frame(identifier="mrn", value="ZZTOPCODE"))
T("watchlist detector builds", is.list(wl) && length(wl) >= 1)
T("watchlist detector catches literal", any(grepl("ZZTOPCODE", se_scan_text("code ZZTOPCODE end", c(det, wl))$match)))
T("date parser handles dd/mm/yyyy", !is.na(se_parse_date_any("15/06/1948")))
T("compact date parser handles yyyymmdd", !is.na(se_parse_compact_date("19480615")))
T("extra= detector hook augments set", length(se_detectors(extra=wl)) > length(det))

sec("PROFILING + MISPLACED-PII (profile.R)")
pr <- se_profile_table(df0)
T("profile_table returns per_column + outliers", is.list(pr) && is.data.frame(pr$outliers))
T("misplaced NRIC flagged in procedure_date", any(pr$outliers$column=="procedure_date" & pr$outliers$severity=="high"))
T("misplaced NRIC flagged in serial_no", any(pr$outliers$column=="serial_no" & pr$outliers$severity=="high"))
T("value_shape signature works", identical(se_value_shape("AB12"), se_value_shape("CD34")))

sec("DE-IDENTIFY TRANSFORMS (deidentify.R)")
policy <- se_empty_policy()
policy$columns <- list(
  patient_name   = list(action="pseudonymize", identifier="name"),
  nric           = list(action="fpe",          identifier="national_id"),
  dob            = list(action="generalize",   identifier="dob", options=list(generalize="year")),
  postal_code    = list(action="generalize",   identifier="postal_code", options=list(generalize="postal_mask")),
  phone          = list(action="redact",        identifier="phone"),
  email          = list(action="redact",        identifier="email"),
  notes          = list(action="redact_freetext"))
policy$freetext_opts <- list(min_conf=0.5, use_pf=FALSE)
policy$conf_overrides <- list()
key <- se_derive_key(k1, "scope:project")
res <- se_deidentify_table(df0, policy, key)
d <- res$data
T("pseudonymize produces stable tokens (prefix NAM-)", all(grepl("^NAM-", d$patient_name)) && d$patient_name[1]==se_deidentify_table(df0,policy,key)$data$patient_name[1])
std <- nchar(df0$nric)==9L   # standard NRIC/FIN (S/T + 7 digits + letter); temp ICs are longer
T("FPE keeps NRIC shape (standard 9-char)", all(nchar(d$nric[std])==9L) && all(d$nric[std] != df0$nric[std]))
T("FPE falls back to pseudonym beyond domain (10-digit temp IC)", { big<-!std; !any(big) || all(grepl("^ID-", d$nric[big])) })
T("generalize date -> year only", all(grepl("^[0-9]{4}$", d$dob[!is.na(d$dob)])))
T("postal mask keeps sector, drops last 3", all(grepl("XXX$", d$postal_code[nchar(df0$postal_code)==6])))
T("redact replaces phone + email", all(d$phone=="[REDACTED]") && all(d$email=="[REDACTED]"))
T("freetext redaction removes NRIC + email in notes[3]", d$notes[3]!=df0$notes[3] && !grepl("@", d$notes[3]) && !grepl(df0$nric[2], d$notes[3]))
T("freetext leaves clean notes untouched", d$notes[1]==df0$notes[1])
cw <- res$crosswalk
T("crosswalk holds reversible pairs", is.data.frame(cw) && nrow(cw)>0 && all(c("column","original","token") %in% names(cw)))
subn <- cw[cw$column=="nric",]
T("re-identify via crosswalk (token->original)", identical(subn$original[match(d$nric[1], subn$token)], df0$nric[1]))
T("re-identify via FPE decrypt", identical(se_fpe(d$nric[1], key, mode="alnum_upper", tweak="natid", decrypt=TRUE), df0$nric[1]))

sec("DATE-SHIFT (interval-preserving + reversible)")
dts <- c("01/01/2020","15/01/2020","01/01/2020")
sh <- se_shift_date(dts, key, salt="visit", subject_id=c("P1","P1","P2"))
iv1 <- as.integer(as.Date(sh[2]) - as.Date(sh[1]))
T("date_shift preserves per-subject interval (14d)", iv1==14L)
T("date_shift differs per subject", sh[1] != sh[3])
T("date_shift hides absolute date", sh[1] != "2020-01-01")

sec("AUDIT HASH-CHAIN (hashchain.R)")
alog <- file.path(tmp, "audit.log")
se_audit_append(alog, "project_create", "alice", list(x=1))
se_audit_append(alog, "deidentify_run", "bob", list(rows=40))
se_audit_append(alog, "signoff", "carol", list(ok=TRUE))
au <- se_audit_read(alog)
T("audit_read returns data.frame of entries", is.data.frame(au) && nrow(au)==3 && "action" %in% names(au))
T("audit chain verifies intact", isTRUE(se_audit_verify(alog)$ok))
lines <- readLines(alog); lines[2] <- sub("bob", "mallory", lines[2]); writeLines(lines, alog)
T("audit chain detects tampering", !isTRUE(se_audit_verify(alog)$ok))

cat(paste(.rows, collapse="\n"), "\n")
cat(sprintf("\n==== SMOKE 1 (core): %d PASS / %d FAIL ====\n", .pass, .fail))
if (.fail > 0) quit(status=1)
