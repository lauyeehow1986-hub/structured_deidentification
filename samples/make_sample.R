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

# Hospital-assigned TEMPORARY IC (patients with no NRIC/FIN): X or Y prefix,
# then 7 or 10 digits, then a trailing letter. No published check-digit.
temp_ic <- function() {
  pre  <- sample(c("X","Y"), 1)
  ndig <- sample(c(7L, 10L), 1)
  paste0(pre, paste0(sample(0:9, ndig, TRUE), collapse = ""), sample(LETTERS, 1))
}

# SG admission / case number: exactly 10 digits then a trailing letter.
case_no <- function() {
  paste0(paste0(sample(0:9, 10, TRUE), collapse = ""), sample(LETTERS, 1))
}

n <- 40
first <- c("Jane","Wei Ming","Siti","Arun","Mei Ling","David","Nurul","Kumar",
           "Xin Yi","Hafiz","Grace","Ryan","Aisha","Jun Jie","Priya")
last  <- c("Tan","Lim","Lee","Kumar","Wong","Ng","Rahman","Chua","Goh","Devi")

df <- data.frame(
  record_id     = sprintf("REC%05d", seq_len(n)),
  patient_name  = paste(sample(first, n, TRUE), sample(last, n, TRUE)),
  nric          = vapply(seq_len(n), function(i) valid_nric(sample(c("S","T"),1)), character(1)),
  case_no       = vapply(seq_len(n), function(i) case_no(), character(1)),
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

# --- plant realistic TEMPORARY ICs (patients with no NRIC/FIN) ---
# Foreigners / unregistered patients carry a hospital temp IC in the NRIC column.
df$nric[5]  <- temp_ic()   # e.g. X1234567A (7-digit form)
df$nric[12] <- temp_ic()   # e.g. Y1234567890B (10-digit form)
df$nric[30] <- temp_ic()

# --- plant MISPLACED PII (the key test cases) ---
# 1. an NRIC accidentally typed into procedure_date
df$procedure_date[7] <- valid_nric("S")
# 2. an NRIC accidentally typed into serial_no
df$serial_no[15] <- valid_nric("T")
# 3. a temp IC accidentally typed into the serial_no column
df$serial_no[9] <- temp_ic()
# 4. an admission case number accidentally typed into the MRN column
df$mrn[18] <- case_no()
# 5. free-text note carrying PII that belongs elsewhere
df$notes[3] <- paste0("Call NOK at 9123 4567; patient NRIC ", valid_nric("S"),
                      ", email next-of-kin at kin.tan@example.com")
df$notes[22] <- "Seen 04/07/2021, lives at Singapore 520123, DOB 15/06/1948."
# 6. free-text note carrying a temp IC and an admission case number
df$notes[11] <- paste0("Foreign patient, temp IC ", temp_ic(),
                       "; admitted under case ", case_no(), ".")

dir.create("samples", showWarnings = FALSE)
write.csv(df, file.path("samples", "sample_patients.csv"), row.names = FALSE)
cat("Wrote samples/sample_patients.csv (", n, "rows )\n")
cat("Planted misplaced NRIC at procedure_date row 7 and serial_no row 15.\n")
cat("Planted temp ICs in nric rows 5/12/30, misplaced temp IC in serial_no row 9,\n")
cat("and a misplaced admission case number in mrn row 18.\n")
