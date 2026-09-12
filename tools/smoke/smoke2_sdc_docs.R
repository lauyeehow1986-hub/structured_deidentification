# Run from the repo root:  Rscript tools/smoke/smoke2_sdc_docs.R
if (!file.exists("app/global.R")) stop("Run from the repo root (where app/ lives).")
suppressWarnings(suppressMessages(source("app/global.R")))
options(stringsAsFactors = FALSE)
tmp <- file.path(tempdir(), paste0("smoke2_", as.integer(runif(1,1,1e6)))); dir.create(tmp)
rd <- function(f) paste(readLines(f, warn=FALSE), collapse="\n")

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

sec("SDC METRICS (sdc.R)")
set.seed(7)
qdf <- data.frame(
  age    = as.numeric(sample(20:80, 60, replace=TRUE)),
  sex    = sample(c("M","F"), 60, replace=TRUE),
  region = sample(c("North","South","East","West"), 60, replace=TRUE),
  dx     = sample(c("A","B","C"), 60, replace=TRUE))
quasi <- c("age","sex","region")
ka <- se_kanon(qdf, quasi, k=5L)
T("k-anonymity computes k_achieved + below-k counts", is.list(ka) && ka$k_achieved>=1L && !is.null(ka$n_below_k))
ld <- se_ldiversity(qdf, quasi, "dx")
T("l-diversity computes l_min", is.list(ld) && ld$l_min>=1L)
su <- se_sample_uniques(qdf, quasi)
T("sample-uniqueness (SUDA-lite) in [0,1]", su$frac_unique_full>=0 && su$frac_unique_full<=1)
ir <- se_individual_risk(qdf, quasi)
T("individual risk (sdcMicro if present, else NULL)", is.null(ir) || is.numeric(ir$risk_max))
dcr_same <- se_dcr(qdf, qdf, quasi)
T("DCR: identical data -> min 0, all rows match", dcr_same$dcr_min==0 && dcr_same$frac_zero==1)
qperturb <- qdf; qperturb$age <- qperturb$age + 25
dcr_far <- se_dcr(qperturb, qdf, quasi)
T("DCR: perturbed data -> larger distance", dcr_far$dcr_mean > dcr_same$dcr_mean)

sec("SDC EXPORT GATE (sdc.R)")
T("gate BLOCKS below threshold (k=100 impossible)", isFALSE(se_sdc_gate(qdf, quasi, list(k=100L, max_risk=1))$pass))
T("gate PASSES when thresholds met (k=1)", isTRUE(se_sdc_gate(qdf, quasi, list(k=1L, max_risk=1))$pass))
T("gate returns human-readable reasons on block", length(se_sdc_gate(qdf, quasi, list(k=100L, max_risk=1))$reasons) >= 1)

sec("SDC RISK-REDUCTION TRANSFORMS (sdc_transforms.R)")
chk <- function(res, n=60L) is.list(res) && is.data.frame(res$data) && nrow(res$data)==n && nzchar(res$note)
T("recode: age -> bands reduces uniqueness", {
  r <- se_sdc_recode(qdf, "age", breaks=c(0,30,45,60,75,200), labels=c("<30","30-44","45-59","60-74","75+"))
  chk(r) && se_kanon(r$data, quasi)$n_unique <= ka$n_unique })
T("suppress: rows below k blanked", { r<-se_sdc_suppress(qdf, quasi, k=5L); chk(r) && any(is.na(r$data[quasi])) })
T("topbottom: extremes capped", { r<-se_sdc_topbottom(qdf, "age", top_pct=0.05, bottom_pct=0.05); chk(r) })
T("microaggregate: numeric averaged in groups", { r<-se_sdc_microaggregate(qdf, "age", aggr=3L); chk(r) })
T("PRAM: categorical perturbed", { r<-se_sdc_pram(qdf, "region", retain=0.8, seed=1L); chk(r) })
T("noise gaussian", { r<-se_sdc_noise(qdf, "age", method="gaussian"); chk(r) })
T("noise laplace (DP-style)", { r<-se_sdc_noise(qdf, "age", method="laplace"); chk(r) })
T("synth marginal breaks joint combo", { r<-se_sdc_synth_marginal(qdf, quasi); chk(r) })
T("synth availability probe returns logical", is.logical(se_sdc_synth_available()))
T("sdc_apply pipeline runs multiple ops + logs", {
  steps <- list(list(op="recode", args=list(col="age", breaks=c(0,45,200), labels=c("<45","45+"))),
                list(op="suppress", args=list(quasi_cols=quasi, k=5L)))
  ap <- se_sdc_apply(qdf, steps); is.data.frame(ap$data) && length(ap$log)==2 })

sec("XML / ECG DE-IDENTIFICATION (xml_scrub.R)")
toks <- c("S1234567D","S2345678B","S5551234Z","S7654321A","MRN0099821")
xkey <- se_derive_key("xml-master-key", "scope:project")
xfiles <- list.files("samples/docs", pattern="\\.xml$", full.names=TRUE)
for (f in xfiles) {
  nm <- basename(f)
  outp <- file.path(tmp, paste0("deid_", nm))
  res <- tryCatch(se_xml_scrub_file(f, outp, key=xkey), error=function(e) e)
  T(sprintf("%s: scrub succeeds + waveform guard OK", nm), !inherits(res,"error") && isTRUE(res$waveform_ok))
  if (!inherits(res,"error")) {
    ins <- rd(f); outs <- rd(outp)
    present <- toks[vapply(toks, function(t) grepl(t, ins, fixed=TRUE), logical(1))]
    T(sprintf("%s: planted PHI IDs removed (%s)", nm, paste(present, collapse=",")),
      length(present)==0 || all(!vapply(present, function(t) grepl(t, outs, fixed=TRUE), logical(1))))
    T(sprintf("%s: output differs from input", nm), !identical(ins, outs))
  }
}
# ECG waveform payload must survive byte-for-byte
for (nm in c("philips_sierraecg.xml","ge_muse.xml")) {
  outp <- file.path(tmp, paste0("deid_", nm))
  T(sprintf("%s: waveform payload preserved", nm), grepl("QkVHSU5f", rd(outp), fixed=TRUE))
}

sec("PDF TRUE REDACTION (pdf_redact.R)")
df0 <- read.csv("samples/sample_patients.csv", colClasses="character")
nricv <- df0$nric[2]
pdf_in <- file.path(tmp, "doc.pdf")
grDevices::pdf(pdf_in, width=8, height=6)
plot.new(); graphics::text(0.05,0.9,"Patient: Wei Ming Tan", pos=4)
graphics::text(0.05,0.8, paste("NRIC", nricv), pos=4)
graphics::text(0.05,0.7,"Email kin.tan@example.com", pos=4)
graphics::text(0.05,0.6,"Seen in clinic; stable.", pos=4)
grDevices::dev.off()
pdf_out <- file.path(tmp, "doc.deid.pdf")
pres <- tryCatch(se_pdf_redact(pdf_in, pdf_out, dpi=120), error=function(e) e)
T("pdf_redact runs + writes output", !inherits(pres,"error") && file.exists(pdf_out))
if (!inherits(pres,"error")) {
  T("pdf_redact detected PII boxes", pres$n_boxes >= 1)
  txt <- paste(pdftools::pdf_text(pdf_out), collapse=" ")
  T("output is image-only: NRIC not recoverable as text", !grepl(nricv, txt, fixed=TRUE))
  T("output is image-only: email not recoverable as text", !grepl("@", txt))
  T("re-OCR verification passed (tokens painted out)", isTRUE(pres$verified))
}

cat(paste(.rows, collapse="\n"), "\n")
cat(sprintf("\n==== SMOKE 2 (SDC + documents): %d PASS / %d FAIL ====\n", .pass, .fail))
if (.fail > 0) quit(status=1)
