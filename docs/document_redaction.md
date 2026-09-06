# Document redaction — PDF, XML, and vendor ECG (Phase 7)

The **Documents** tab de-identifies whole documents, complementing the table
pipeline. Everything runs **in-process in R** over bundled packages
(`pdftools`, `tesseract`, `magick`, `xml2`) — no subprocess, no network, and no
unsigned external binary to be quarantined by antivirus. Detection reuses the
same deterministic detectors as the table pipeline (`app/R/detect_r.R`).

When a project is open the redacted file is written to `outputs/`, hashed into
`manifest.json`, and the action is recorded in the tamper-evident audit log
(`xml_scrub` / `pdf_redact`). With no project open you can still redact ad-hoc:
the output goes to a temp file for download and is **not** logged.

## PDF — true redaction (`app/R/pdf_redact.R`)

`se_pdf_redact(input, output, dpi = 150, force_ocr = FALSE, verify = TRUE)`

1. **Locate PII.** For a page with a text layer, word bounding boxes come from
   `pdftools::pdf_data`; the words are reconstructed into text, the detectors find
   identifier spans, and each span is mapped back to the boxes it covers (so
   multi-word matches like a spaced phone number are fully covered). A page with
   **no** text layer (or `force_ocr = TRUE`) is OCR'd with Tesseract
   (`tesseract::ocr_data`), which returns word boxes directly in pixel space.
2. **Remove, don't cover.** Every page is rendered to a raster, the PII boxes are
   painted solid black, and the pages are reassembled into an **image-only PDF**.
   Rasterising drops the original text/vector layer entirely — redacted content
   cannot be recovered by copy-paste, text extraction, or deleting a black box.
   Trade-off: the output has no selectable text and is larger. This is the correct
   default for a governance de-identification tool; it is not a cosmetic overlay.
3. **Verify (fail closed).** With `verify = TRUE` the painted regions of the
   *output* are re-OCR'd and the run reports `verified = FALSE` if any target
   token is still readable.

`se_pdf_detect(...)` returns the findings per page without redacting (review step).

**Limitation — names.** The deterministic detectors catch the structured
identifiers (NRIC/FIN, phone, email, dates, postal, MRN, …). Free-text **person
names** need the NER/LLM engine; pass an NER-backed scanner via the `scan_fn`
argument (`text -> data.frame(start,end,type,identifier)`) to also redact names.

## XML — tree scrub with waveform preservation (`app/R/xml_scrub.R`)

`se_xml_scrub(input, key, profile = NULL, sweep = TRUE, actions = NULL)` /
`se_xml_scrub_file(input, output, key, ...)`

Profiles (auto-detected from the root element + namespace):

| Profile   | Root / namespace                    | Notes                                  |
|-----------|-------------------------------------|----------------------------------------|
| `philips` | `restingecgdata` / medical.philips  | Philips SierraECG / iECG               |
| `muse`    | `RestingECG`                        | GE MUSE                                 |
| `cda`     | `ClinicalDocument` / hl7-org:v3     | HL7 CDA R2                             |
| `fhir`    | hl7.org/fhir (`Patient`/`Bundle`)   | FHIR XML                              |
| `generic` | anything else                       | value-level sweep only                 |

All XPaths use `local-name()`, so a document's namespace prefixes (or a default
namespace with no prefix) never break matching across vendors.

Per profile, demographic / test-header PHI is transformed:

- patient **name** parts → keyed pseudonym token (`se_pseudonymize`)
- **NRIC / patient ID / MRN** → keyed pseudonym token
- **DOB / acquisition date** → **year only** (day + month dropped)
- acquisition **time** → redacted
- **postal code** → **mask the last 3 digits** (`se_mask_postal`): keep the
  sector/area prefix, drop the precise last three that pinpoint the building
  (`169609` → `169XXX`). This is also the postal default in the table pipeline
  (identifier `postal_code`, generalize method `postal_mask`).
- **institution / site / department / operator / technician / over-reader** → redacted

**Waveform payloads are preserved byte-for-byte.** The scrubber never selects a
waveform node (`parsedwaveforms` / `Waveform` / `WaveFormData`), and a post-scrub
guard asserts every protected node is unchanged. `se_xml_scrub_file` refuses to
write when the guard trips (`waveform_ok = FALSE`).

`sweep = TRUE` additionally runs a **high-precision** value-level scan
(NRIC / email / phone / postal only — never the loose date/MRN detectors, to avoid
clobbering measurements) over leaf text nodes **outside** the protected subtree,
redacting stray PHI in free-text fields.

`actions` overrides the action per identifier id (e.g.
`list(name = "redact")`); pass `key = NULL` only if no target pseudonymizes.

## Bare 6-digit numbers as postal codes (opt-in)

A bare 6-digit run (e.g. `408600`) is ambiguous — it could be a postal code, an
account number, or a measurement — so it is **not** treated as a postal code by
default. Turn on the **"Treat bare 6-digit numbers as postal codes"** checkbox on
the Documents tab (or set `options(se.detect_postal6 = TRUE)` globally) to opt in.
When on, `se_detectors()` includes a low-priority `postal6` detector and bare
6-digit runs are handled as postal codes: **masked** (last 3 digits) in XML and
the table pipeline, **redacted** (whole token blacked out) in PDFs. Overlap
dedup (`se_dedup_overlaps`) ensures a `Singapore 521123` span and the `521123`
inside it are transformed once, not twice.

## Samples & tests

`Rscript samples/make_xml_samples.R` writes five synthetic documents (all PHI is
invented) under `samples/docs/`. Headless self-tests cover the XML scrub (every
profile: header PHI removed, waveform preserved, keyed pseudonyms stable,
generic sweep), the PDF redactor (detect, flatten removes the text layer, OCR
guard confirms targets unreadable while clinical text survives), and the
`testServer` wiring of the Documents tab.
