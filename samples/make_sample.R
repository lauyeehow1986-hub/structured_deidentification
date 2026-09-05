# make_sample.R — generate a fully synthetic dataset with planted + MISPLACED
# PII for testing. No real patient data. Run:
#   Rscript samples/make_sample.R
# Writes samples/sample_patients.csv

set.seed(42)
source(file.path("app", "R", "detect_r.R"))

valid_nric <- function(prefix = "S") {
  repeat {
    digits <- paste0(sample(0:9, 7, replace = TRUE), collapse = "")
    for (L in LETTERS) {
      cand <- paste0(prefix, digits, L)
      if (se_nric_valid(cand)) return(cand)
    }
  }
}

n <- 40
first <- c("Jane","Wei Ming","Siti","Arun","Mei Ling","David","Nurul","Kumar",
           "Xin Yi","Hafiz","Grace","Ryan","Aisha","Jun Jie","Priya")
last  <- c("Tan","Lim","Lee","Kumar","Wong","Ng","Rahman","Chua","Goh","Devi")

df <- data.frame(
  record_id     = sprintf("REC%05d", seq_len(n)),
  patient_name  = paste(sample(first, n, TRUE), sample(last, n, TRUE)),
  nric          = vapply(seq_len(n), function(i) valid_nric(sample(c("S","T"),1)), character(1)),
  mrn           = sprintf("MRN%07d", sample(1e5:9e5, n)),
  dob           = format(as.Date("1950-01-01") + sample(0:20000, n), "%d/%m/%Y"),
  phone         = sprintf("+65 %d%03d %04d", sample(c(8,9),n,TRUE), sample(0:999,n), sample(0:9999,n)),
  email         = tolower(gsub(" ", ".", paste0(sample(first,n,TRUE), "@example.com"))),
  postal_code   = sprintf("%06d", sample(1e5:8e5, n)),
  procedure_date= format(as.Date("2019-01-01") + sample(0:1500, n), "%d/%m/%Y"),
  serial_no     = sprintf("SN-%06d", sample(1e5:9e5, n)),
  notes         = "Patient reviewed in clinic; stable.",
  stringsAsFactors = FALSE
)

# --- plant MISPLACED PII (the key test cases) ---
# 1. an NRIC accidentally typed into procedure_date
df$procedure_date[7] <- valid_nric("S")
# 2. an NRIC accidentally typed into serial_no
df$serial_no[15] <- valid_nric("T")
# 3. free-text note carrying PII that belongs elsewhere
df$notes[3] <- paste0("Call NOK at 9123 4567; patient NRIC ", valid_nric("S"),
                      ", email next-of-kin at kin.tan@example.com")
df$notes[22] <- "Seen 04/07/2021, lives at Singapore 520123, DOB 15/06/1948."

dir.create("samples", showWarnings = FALSE)
write.csv(df, file.path("samples", "sample_patients.csv"), row.names = FALSE)
cat("Wrote samples/sample_patients.csv (", n, "rows )\n")
cat("Planted misplaced NRIC at procedure_date row 7 and serial_no row 15.\n")
