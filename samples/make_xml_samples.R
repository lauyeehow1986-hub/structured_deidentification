# make_xml_samples.R — synthetic XML/ECG documents with planted (fake) PHI.
#
# Generates one file per supported XML profile under samples/docs/:
#   philips_sierraecg.xml   Philips SierraECG / iECG resting ECG
#   ge_muse.xml             GE MUSE resting ECG
#   hl7_cda.xml             HL7 CDA R2 clinical document
#   fhir_patient.xml        FHIR R4 Patient resource
#   generic.xml             vendor-neutral record (tests the generic sweep)
#
# EVERY name / ID / date / phone / address below is INVENTED. No real patient
# data. Each ECG carries a distinctive <...waveform...> payload so tests can
# assert the waveform survives de-identification byte-for-byte.

se_make_xml_samples <- function(dir = file.path("samples", "docs")) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  # A recognisable fake "waveform" payload (base64-looking) used to prove the
  # scrubber never touches the signal. Long enough to be obviously the payload.
  wf <- paste0(
    "QkVHSU5fV0FWRUZPUk1fUEFZTE9BRF9ETy1OT1QtVE9VQ0hf",
    strrep("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5", 6),
    "X0VORF9XQVZFRk9STV9QQVlMT0FE")

  files <- character(0)

  # ---- Philips SierraECG / iECG -------------------------------------------
  philips <- sprintf('<?xml version="1.0" encoding="UTF-8"?>
<restingecgdata xmlns="http://www3.medical.philips.com/PMS/ECG">
  <documentinfo>
    <documentname>ECG_00012345.xml</documentname>
    <documentid>DOC-2025-0098231</documentid>
  </documentinfo>
  <patient>
    <generalpatientdata>
      <name>
        <lastname>Tan</lastname>
        <firstname>Wei Ming</firstname>
        <middlename>Bernard</middlename>
      </name>
      <patientid>S1234567D</patientid>
      <age><years>54</years><dateofbirth>1971-03-12</dateofbirth></age>
      <sex>Male</sex>
    </generalpatientdata>
  </patient>
  <dataacquisition date="2025-06-14" time="09:32:11">
    <institution>National Heart Centre Singapore</institution>
    <department>Cardiology</department>
    <acquirer>
      <lastname>Lim</lastname>
      <firstname>Priya</firstname>
    </acquirer>
    <machine model="PageWriter TC70" id="ECG-CATH2"/>
  </dataacquisition>
  <interpretations>
    <interpretation>
      <statement><leftstatement>Sinus rhythm. Normal ECG.</leftstatement></statement>
    </interpretation>
  </interpretations>
  <waveforms>
    <parsedwaveforms>%s</parsedwaveforms>
  </waveforms>
</restingecgdata>', wf)
  fp <- file.path(dir, "philips_sierraecg.xml"); writeLines(philips, fp); files <- c(files, fp)

  # ---- GE MUSE -------------------------------------------------------------
  muse <- sprintf('<?xml version="1.0" encoding="UTF-8"?>
<RestingECG>
  <PatientDemographics>
    <PatientID>MRN0099821</PatientID>
    <PatientLastName>Kumar</PatientLastName>
    <PatientFirstName>Anand</PatientFirstName>
    <DateofBirth>03-15-1968</DateofBirth>
    <Gender>MALE</Gender>
    <Race>ASIAN</Race>
  </PatientDemographics>
  <TestDemographics>
    <AcquisitionDate>06-14-2025</AcquisitionDate>
    <AcquisitionTime>10:05:44</AcquisitionTime>
    <SiteName>NHCS Cath Lab 2</SiteName>
    <Location>12</Location>
    <AcquisitionTechnician>NURSE FARIDAH</AcquisitionTechnician>
    <OverreadingPhysician>DR CHUA S H</OverreadingPhysician>
    <EditorID>tech0421</EditorID>
  </TestDemographics>
  <Diagnosis>
    <DiagnosisStatement><StmtText>NORMAL SINUS RHYTHM</StmtText></DiagnosisStatement>
  </Diagnosis>
  <Waveform>
    <WaveformType>Rhythm</WaveformType>
    <SampleBase>500</SampleBase>
    <WaveFormData>%s</WaveFormData>
  </Waveform>
</RestingECG>', wf)
  fp <- file.path(dir, "ge_muse.xml"); writeLines(muse, fp); files <- c(files, fp)

  # ---- HL7 CDA R2 ----------------------------------------------------------
  cda <- '<?xml version="1.0" encoding="UTF-8"?>
<ClinicalDocument xmlns="urn:hl7-org:v3">
  <recordTarget>
    <patientRole>
      <id extension="S7654321A" root="2.16.840.1.113883.3.1"/>
      <addr>
        <streetAddressLine>10 Hospital Boulevard</streetAddressLine>
        <city>Singapore</city>
        <postalCode>169609</postalCode>
      </addr>
      <telecom value="tel:+6598765432"/>
      <patient>
        <name><given>Sarah</given><family>Goh</family></name>
        <administrativeGender code="F"/>
        <birthTime value="19800722"/>
      </patient>
    </patientRole>
  </recordTarget>
  <author>
    <assignedAuthor>
      <assignedPerson><name><given>Rajesh</given><family>Kumar</family></name></assignedPerson>
    </assignedAuthor>
  </author>
  <component>
    <structuredBody>
      <component><section>
        <title>Assessment</title>
        <text>Normal sinus rhythm. No acute changes.</text>
      </section></component>
    </structuredBody>
  </component>
</ClinicalDocument>'
  fp <- file.path(dir, "hl7_cda.xml"); writeLines(cda, fp); files <- c(files, fp)

  # ---- FHIR R4 Patient -----------------------------------------------------
  fhir <- '<?xml version="1.0" encoding="UTF-8"?>
<Patient xmlns="http://hl7.org/fhir">
  <identifier>
    <system value="https://nric.sg"/>
    <value value="S5551234Z"/>
  </identifier>
  <name>
    <family value="Wong"/>
    <given value="Mei Ling"/>
  </name>
  <telecom>
    <system value="phone"/>
    <value value="+6591234567"/>
  </telecom>
  <gender value="female"/>
  <birthDate value="1990-11-05"/>
  <address>
    <line value="Blk 5 Toa Payoh Lorong 8"/>
    <city value="Singapore"/>
    <postalCode value="310005"/>
  </address>
</Patient>'
  fp <- file.path(dir, "fhir_patient.xml"); writeLines(fhir, fp); files <- c(files, fp)

  # ---- generic (unknown vendor) -------------------------------------------
  # No recognised root: exercises the value-level sweep over leaf text nodes.
  generic <- '<?xml version="1.0" encoding="UTF-8"?>
<record>
  <subject>
    <contact>Reach patient at +65 8123 4567 or jane.lee@example.com</contact>
    <nric>S2345678B</nric>
    <note>Lives at Blk 12 Bedok, Singapore 521123; follow up scheduled.</note>
  </subject>
  <measurements>
    <hr unit="bpm">72</hr>
    <qtc unit="ms">430</qtc>
  </measurements>
</record>'
  fp <- file.path(dir, "generic.xml"); writeLines(generic, fp); files <- c(files, fp)

  invisible(files)
}

if (identical(environment(), globalenv()) && !interactive()) {
  fs <- se_make_xml_samples()
  cat("Wrote:\n"); cat(paste0("  ", fs, collapse = "\n"), "\n")
}
