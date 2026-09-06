# identifiers.R — the SingHealth 15-identifier catalogue and default policy.
#
# These are the 15 direct/indirect identifiers mandated by the SingHealth data
# governance model (PDPA + HBRA). The set is still editable per project via the
# Policy tab, but this is the canonical default.
#
# Each identifier declares:
#   id            stable key
#   label         human name
#   category      "direct" | "quasi" | "other"
#   default_action  "pseudonymize","fpe","generalize","redact","keep"
#   detectors     detector names in detect_r.R and/or NER labels
#   fpe_mode      "digits" | "alnum_upper" (used only when action == "fpe")
#   generalize    method hint for action == "generalize"
#   salt          per-identifier salt so tokens differ across identifier types
#
# Note: for account/case numbers "frequently masked using SHA-256", the default
# "pseudonymize" action IS a keyed HMAC-SHA256 token (see crypto.R).

se_default_identifiers <- function() {
  list(
    # 1. Names
    list(id="name",        label="Names (full, aliases, initials)", category="direct",
         default_action="pseudonymize", detectors=c("PERSON"), salt="name"),
    # 2. National identification numbers (NRIC / FIN / birth cert / passport)
    list(id="national_id", label="National ID (NRIC/FIN/passport/birth cert)", category="direct",
         default_action="pseudonymize", detectors=c("nric","passport"),
         fpe_mode="alnum_upper", salt="natid"),
    # 3. Medical Record Numbers
    list(id="mrn",         label="Medical Record Number (MRN)", category="direct",
         default_action="pseudonymize", detectors=c("mrn"),
         fpe_mode="alnum_upper", salt="mrn"),
    # 4. Case / Visit numbers (episode / admission / billing) — often SHA-256 masked
    list(id="case_visit",  label="Case / Visit / Episode number", category="direct",
         default_action="pseudonymize", detectors=c("case","mrn"),
         fpe_mode="alnum_upper", salt="case"),
    # 5. Mailing / residential addresses
    list(id="address",     label="Mailing / residential address", category="quasi",
         default_action="generalize",   detectors=c("address","LOCATION"),
         generalize="region", salt="addr"),
    # 6. Postal codes
    list(id="postal_code", label="Postal code", category="quasi",
         default_action="generalize",   detectors=c("postal"),
         generalize="postal_mask", salt="postal"),
    # 7. Telephone / mobile numbers
    list(id="phone",       label="Telephone / mobile number", category="direct",
         default_action="pseudonymize", detectors=c("phone"), salt="phone"),
    # 8. Fax numbers
    list(id="fax",         label="Fax number", category="direct",
         default_action="redact",       detectors=c("fax","phone"), salt="fax"),
    # 9. Email addresses
    list(id="email",       label="Email address", category="direct",
         default_action="redact",       detectors=c("email"), salt="email"),
    # 10. Full dates of birth (day+month removed; year retained as demographic tier)
    list(id="dob",         label="Date of birth (keep year only)", category="quasi",
         default_action="generalize",   detectors=c("date"), generalize="year", salt="dob"),
    # 11. Dates of death (precise date removed)
    list(id="date_of_death", label="Date of death", category="quasi",
         default_action="generalize",   detectors=c("date"), generalize="year", salt="dod"),
    # 12. Device identifiers and serial numbers
    list(id="device",      label="Device identifier / serial number", category="direct",
         default_action="pseudonymize", detectors=c("serial"), salt="dev"),
    # 13. Biometric identifiers
    list(id="biometric",   label="Biometric identifier", category="direct",
         default_action="redact",       detectors=c("biometric"), salt="bio"),
    # 14. Full-face photographic images
    list(id="photo",       label="Full-face photographic image", category="direct",
         default_action="redact",       detectors=c("image"), salt="photo"),
    # 15. Other unique characteristics / local codes / identifying free text
    list(id="other_id",    label="Other unique identifier / code / free text", category="other",
         default_action="pseudonymize", detectors=c("other","url","ip","account"), salt="other")
  )
}

#' Build the default per-project policy: a named list keyed by column, filled in
#' once columns are mapped to identifiers. Empty by default.
se_empty_policy <- function() {
  list(columns = list(), freetext_columns = character(0))
}

se_action_choices <- function() {
  c("Pseudonymize (keyed SHA-256 token)" = "pseudonymize",
    "Format-preserving (keep shape)" = "fpe",
    "Generalize" = "generalize",
    "Redact / remove" = "redact",
    "Redact detected PII in free text" = "redact_freetext",
    "Keep as-is" = "keep")
}

#' Look up an identifier definition by id.
se_identifier <- function(id, catalogue = se_default_identifiers()) {
  for (d in catalogue) if (identical(d$id, id)) return(d)
  NULL
}
