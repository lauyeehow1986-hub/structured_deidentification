# xml_scrub.R — de-identify XML documents by tree-walk, preserving payload.
#
# Pure R (xml2). Handles four structured profiles plus a generic fallback:
#   philips  Philips SierraECG / iECG  (root <restingecgdata>)
#   muse     GE MUSE resting ECG        (root <RestingECG>)
#   cda      HL7 CDA R2                 (root <ClinicalDocument>)
#   fhir     FHIR Patient/Bundle        (FHIR namespace)
#   generic  anything else              (value-level sweep of leaf text nodes)
#
# For the two vendor ECG profiles the goal is to scrub demographic / test-header
# PHI (patient name, ID, DOB, acquisition date-time, institution/site/operator/
# over-reader) while leaving the WAVEFORM PAYLOAD untouched — the scrubber never
# selects a waveform node, and a post-scrub guard asserts every protected node is
# byte-for-byte identical (fails closed: waveform_ok = FALSE aborts the caller).
#
# All XPaths use local-name() so a document's namespace prefixes (or lack of a
# prefix on a default namespace) never break matching across vendors.
#
# Actions reuse the table engine's transforms:
#   pseudonymize      keyed HMAC token (crypto.R se_pseudonymize) — needs a key
#   generalize_year   keep the 4-digit year only (drops day+month)
#   redact            replace with a fixed placeholder
#   keep              leave as-is (declared for clarity/audit)
#
# Returns a scrubbed XML string, the detected profile, a per-change log (same
# spirit as the findings schema), and the waveform-preservation verdict.

# --- profile detection -------------------------------------------------------

#' Detect the XML profile from the root element + namespace.
se_xml_profile <- function(doc) {
  root <- xml2::xml_root(doc)
  rn <- tolower(xml2::xml_name(root))
  ns <- tryCatch(paste(xml2::xml_ns(doc), collapse = " "), error = function(e) "")
  ns <- tolower(ns)
  if (rn == "restingecgdata" || grepl("medical.philips.com", ns)) return("philips")
  if (rn == "restingecg") return("muse")
  if (rn == "clinicaldocument" || grepl("hl7-org:v3", ns)) return("cda")
  if (grepl("hl7.org/fhir", ns) || rn %in% c("patient", "bundle")) return("fhir")
  "generic"
}

#' Waveform / signal-payload XPaths per profile — never scrubbed, and asserted
#' unchanged afterwards. (local-name based; empty for non-signal profiles.)
se_xml_protected_paths <- function(profile) {
  switch(profile,
    philips = c("//*[local-name()='parsedwaveforms']",
                "//*[local-name()='waveforms']"),
    muse    = c("//*[local-name()='WaveFormData']",
                "//*[local-name()='Waveform']"),
    character(0))
}

# --- per-profile scrub target tables ----------------------------------------
# Each target: xpath (local-name based), identifier id (see identifiers.R),
# action, and for attribute-valued targets the attribute name.

.se_target <- function(xpath, id, action, attr = NULL)
  list(xpath = xpath, id = id, action = action, attr = attr)

se_xml_targets <- function(profile) {
  switch(profile,
    philips = list(
      .se_target("//*[local-name()='name']/*[local-name()='firstname']",  "name", "pseudonymize"),
      .se_target("//*[local-name()='name']/*[local-name()='lastname']",   "name", "pseudonymize"),
      .se_target("//*[local-name()='name']/*[local-name()='middlename']", "name", "pseudonymize"),
      .se_target("//*[local-name()='acquirer']/*[local-name()='firstname']", "name", "redact"),
      .se_target("//*[local-name()='acquirer']/*[local-name()='lastname']",  "name", "redact"),
      .se_target("//*[local-name()='patientid']",   "national_id", "pseudonymize"),
      .se_target("//*[local-name()='documentid']",  "other_id",    "pseudonymize"),
      .se_target("//*[local-name()='dateofbirth']", "dob",         "generalize_year"),
      .se_target("//*[local-name()='institution']", "address",     "redact"),
      .se_target("//*[local-name()='department']",  "address",     "redact"),
      .se_target("//*[local-name()='dataacquisition']", "date_of_death", "generalize_year", attr = "date"),
      .se_target("//*[local-name()='dataacquisition']", "other_id",      "redact",          attr = "time")
    ),
    muse = list(
      .se_target("//*[local-name()='PatientID']",        "mrn",         "pseudonymize"),
      .se_target("//*[local-name()='PatientLastName']",  "name",        "pseudonymize"),
      .se_target("//*[local-name()='PatientFirstName']", "name",        "pseudonymize"),
      .se_target("//*[local-name()='DateofBirth']",      "dob",         "generalize_year"),
      .se_target("//*[local-name()='AcquisitionDate']",  "date_of_death","generalize_year"),
      .se_target("//*[local-name()='AcquisitionTime']",  "other_id",    "redact"),
      .se_target("//*[local-name()='SiteName']",         "address",     "redact"),
      .se_target("//*[local-name()='Location']",         "address",     "redact"),
      .se_target("//*[local-name()='AcquisitionTechnician']", "name",   "redact"),
      .se_target("//*[local-name()='OverreadingPhysician']",  "name",   "redact"),
      .se_target("//*[local-name()='RequestingMD']",     "name",        "redact"),
      .se_target("//*[local-name()='ReferringMD']",      "name",        "redact"),
      .se_target("//*[local-name()='EditorID']",         "other_id",    "pseudonymize")
    ),
    cda = list(
      .se_target("//*[local-name()='patientRole']/*[local-name()='id']", "national_id", "pseudonymize", attr = "extension"),
      .se_target("//*[local-name()='patient']//*[local-name()='given']",  "name", "pseudonymize"),
      .se_target("//*[local-name()='patient']//*[local-name()='family']", "name", "pseudonymize"),
      .se_target("//*[local-name()='birthTime']", "dob", "generalize_year", attr = "value"),
      .se_target("//*[local-name()='addr']/*[local-name()='streetAddressLine']", "address", "redact"),
      .se_target("//*[local-name()='addr']/*[local-name()='postalCode']", "postal_code", "mask_postal"),
      .se_target("//*[local-name()='telecom']", "phone", "redact", attr = "value"),
      .se_target("//*[local-name()='author']//*[local-name()='given']",  "name", "redact"),
      .se_target("//*[local-name()='author']//*[local-name()='family']", "name", "redact")
    ),
    fhir = list(
      .se_target("//*[local-name()='identifier']/*[local-name()='value']", "national_id", "pseudonymize", attr = "value"),
      .se_target("//*[local-name()='name']/*[local-name()='family']", "name", "pseudonymize", attr = "value"),
      .se_target("//*[local-name()='name']/*[local-name()='given']",  "name", "pseudonymize", attr = "value"),
      .se_target("//*[local-name()='telecom']/*[local-name()='value']", "phone", "redact", attr = "value"),
      .se_target("//*[local-name()='birthDate']", "dob", "generalize_year", attr = "value"),
      .se_target("//*[local-name()='address']/*[local-name()='line']", "address", "redact", attr = "value"),
      .se_target("//*[local-name()='address']/*[local-name()='postalCode']", "postal_code", "mask_postal", attr = "value")
    ),
    list()  # generic: no structured targets, sweep only
  )
}

# --- value transforms --------------------------------------------------------

# Robust 4-digit year extractor across YYYY-MM-DD, MM-DD-YYYY, YYYYMMDD, etc.
.se_year_of <- function(x) {
  x <- as.character(x)
  m <- regmatches(x, regexpr("(18|19|20)[0-9]{2}", x))
  if (length(m) && nzchar(m)) m else "[DATE]"
}

.se_id_prefix <- function(id) {
  switch(id, name = "NAME", national_id = "ID", mrn = "MRN",
         case_visit = "CASE", other_id = "UID", phone = "PHONE", id_toupper = id,
         toupper(substr(id, 1, 4)))
}

.se_xml_transform <- function(value, action, id, key) {
  value <- as.character(value)
  if (is.na(value) || !nzchar(trimws(value))) return(value)
  switch(action,
    pseudonymize = {
      if (is.null(key)) stop("se_xml_scrub: a key is required for pseudonymize actions")
      ndef <- se_identifier(id)
      salt <- if (!is.null(ndef)) ndef$salt else id
      tok <- se_pseudonymize(value, key, prefix = .se_id_prefix(id), salt = salt)
      if (is.na(tok)) "[REDACTED]" else tok
    },
    generalize_year = .se_year_of(value),
    mask_postal = se_mask_postal(value),
    redact = "[REDACTED]",
    keep = value,
    value)
}

# --- the scrubber ------------------------------------------------------------

#' De-identify an XML document.
#'
#' @param input  a file path or a raw XML string.
#' @param key    key material for pseudonymize actions (see keystore.R). May be
#'               NULL only if no target uses pseudonymize (else those error).
#' @param profile force a profile; default auto-detects.
#' @param sweep  also run a high-precision value-level scan (NRIC/email/phone/
#'               postal) over leaf text nodes OUTSIDE protected subtrees, redacting
#'               any hit. Default TRUE. Catches stray PHI in free-text fields.
#' @param actions optional named list overriding the action per identifier id.
#' @return list(xml, profile, changes, waveform_ok, protected_nodes, n_changes)
se_xml_scrub <- function(input, key = NULL, profile = NULL, sweep = TRUE,
                         actions = NULL) {
  doc <- if (is.character(input) && length(input) == 1 && file.exists(input))
    xml2::read_xml(input) else xml2::read_xml(paste(input, collapse = "\n"))

  if (is.null(profile)) profile <- se_xml_profile(doc)
  protected <- se_xml_protected_paths(profile)

  # capture protected payloads BEFORE any edit, to assert they survive.
  prot_nodes <- list()
  for (px in protected) prot_nodes <- c(prot_nodes, xml2::xml_find_all(doc, px))
  prot_before <- vapply(prot_nodes, function(n) xml2::xml_text(n), character(1))

  changes <- list()
  rec <- function(xpath, id, action, before, after, detector) {
    if (identical(as.character(before), as.character(after))) return(invisible())
    changes[[length(changes) + 1L]] <<- data.frame(
      profile = profile, xpath = xpath, identifier = id, action = action,
      detector = detector, before = before, after = after,
      stringsAsFactors = FALSE)
  }

  # 1) structured targets
  for (t in se_xml_targets(profile)) {
    act <- t$action
    if (!is.null(actions) && !is.null(actions[[t$id]])) act <- actions[[t$id]]
    if (identical(act, "keep")) next
    nodes <- xml2::xml_find_all(doc, t$xpath)
    for (nd in nodes) {
      if (is.null(t$attr)) {
        # only scrub leaf text (never clobber a node that has element children)
        if (length(xml2::xml_children(nd)) > 0) next
        before <- xml2::xml_text(nd)
        if (!nzchar(trimws(before))) next
        after <- .se_xml_transform(before, act, t$id, key)
        xml2::xml_text(nd) <- after
      } else {
        before <- xml2::xml_attr(nd, t$attr)
        if (is.na(before) || !nzchar(before)) next
        after <- .se_xml_transform(before, act, t$id, key)
        xml2::xml_set_attr(nd, t$attr, after)
      }
      rec(t$xpath, t$id, act, before, after, "xml:profile")
    }
  }

  # 2) value-level sweep (high-precision detectors only), excluding protected
  if (isTRUE(sweep)) {
    # high-precision detectors only; include the opt-in bare-6-digit postal when
    # options(se.detect_postal6=TRUE) so stray 6-digit codes get masked too.
    sweep_dets <- se_detectors()[c("nric", "email", "phone", "postal", "postal6")]
    sweep_dets <- sweep_dets[!vapply(sweep_dets, is.null, logical(1))]
    excl <- ""  # keep length-1 even when there are no protected paths
    if (length(protected))
      excl <- paste0("[not(ancestor-or-self::", sub("^//\\*", "*", protected), ")]",
                     collapse = "")
    # leaf elements with non-empty text, not inside a protected subtree
    leaf_xpath <- paste0("//*[not(*)][normalize-space(text())]", excl)
    leaves <- xml2::xml_find_all(doc, leaf_xpath)
    for (nd in leaves) {
      before <- xml2::xml_text(nd)
      spans <- se_scan_text(before, detectors = sweep_dets)
      if (!nrow(spans)) next
      spans <- se_dedup_overlaps(spans)
      after <- before
      # apply right-to-left so earlier offsets stay valid
      ord <- order(spans$start, decreasing = TRUE)
      for (i in ord) {
        s <- spans$start[i]; e <- spans$end[i]
        matched <- substr(after, s, e)
        # postal codes are masked (keep sector, drop last 3); others redacted
        repl <- if (identical(spans$type[i], "postal")) se_mask_postal(matched)
                else "[REDACTED]"
        after <- paste0(substr(after, 1, s - 1L), repl,
                        substr(after, e + 1L, nchar(after)))
      }
      if (!identical(after, before)) {
        xml2::xml_text(nd) <- after
        rec(xml2::xml_path(nd), "other_id", "redact_freetext", before, after,
            paste0("xml:sweep(", paste(unique(spans$type), collapse = ","), ")"))
      }
    }
  }

  # 3) waveform-preservation guard (fail closed)
  prot_after <- vapply(prot_nodes, function(n) xml2::xml_text(n), character(1))
  waveform_ok <- length(prot_before) == length(prot_after) &&
    all(prot_before == prot_after)

  changes_df <- if (length(changes)) do.call(rbind, changes) else
    data.frame(profile = character(0), xpath = character(0),
               identifier = character(0), action = character(0),
               detector = character(0), before = character(0),
               after = character(0), stringsAsFactors = FALSE)

  list(
    xml = as.character(doc),
    profile = profile,
    changes = changes_df,
    n_changes = nrow(changes_df),
    protected_nodes = length(prot_nodes),
    waveform_ok = waveform_ok
  )
}

#' Convenience: scrub an XML file to an output path. Refuses to write when the
#' waveform-preservation guard trips.
se_xml_scrub_file <- function(input, output, key = NULL, ...) {
  res <- se_xml_scrub(input, key = key, ...)
  if (!isTRUE(res$waveform_ok))
    stop("se_xml_scrub_file: waveform-preservation guard failed; refusing to write")
  writeLines(res$xml, output)
  res$output <- output
  invisible(res)
}
