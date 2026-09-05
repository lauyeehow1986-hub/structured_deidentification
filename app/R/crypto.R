# crypto.R — keyed hashing, format-preserving encryption (FPE), AEAD crosswalk,
# and detached signatures for the de-identification pipeline.
#
# Design notes
# ------------
# * Everything here is pure-R over {openssl, sodium} so it bundles into the
#   portable runtime with no native build step (locked-down Windows box).
# * Two key scopes are supported everywhere a key is taken:
#     - "global"  : one key shared across all projects  -> stable tokens that
#                   link the same person across datasets/projects.
#     - "project" : a per-project key                   -> tokens isolated to
#                   one project (cannot be linked across projects).
#   Callers pass the already-resolved raw key; see keystore.R for where the
#   bytes come from.
# * Pseudonymisation is a keyed hash (HMAC-SHA256). It is one-way; authorised
#   re-identification is served by the AEAD-encrypted crosswalk, NOT by
#   reversing the hash.

# --- low level helpers -------------------------------------------------------

.se_as_raw_key <- function(key) {
  if (is.raw(key)) return(key)
  if (is.character(key)) return(charToRaw(paste(key, collapse = "")))
  stop("key must be raw or character")
}

#' Derive a 32-byte subkey from a master key and a text label.
#' Lets one stored master key serve several purposes (hash vs crosswalk vs sign)
#' without reusing the exact same bytes.
se_derive_key <- function(master_key, label, size = 32L) {
  mk <- .se_as_raw_key(master_key)
  # HMAC-SHA256(master, label) truncated/streamed to `size` bytes.
  out <- raw(0)
  counter <- 1L
  while (length(out) < size) {
    block <- openssl::sha256(c(charToRaw(paste0(label, ":", counter))), key = mk)
    out <- c(out, block)
    counter <- counter + 1L
  }
  out[seq_len(size)]
}

# --- pseudonymisation (keyed hash -> stable token) ---------------------------

#' Turn a value into a stable, keyed pseudonym token.
#'
#' @param values   character vector of source values.
#' @param key      raw/character key (already scoped to global or project).
#' @param prefix   short tag prepended to the token, e.g. "PT" -> "PT-3f9a1c...".
#' @param nchar_hex number of hex chars kept from the digest (collision budget).
#' @param salt     optional per-identifier salt so the same value hashes to
#'                 different tokens for, say, NRIC vs MRN.
#' @return character vector of tokens; NA in -> NA out.
se_pseudonymize <- function(values, key, prefix = "ID",
                            nchar_hex = 16L, salt = "") {
  k <- se_derive_key(key, paste0("pseudonym:", salt))
  vapply(values, function(v) {
    if (is.na(v) || !nzchar(trimws(as.character(v)))) return(NA_character_)
    dig <- openssl::sha256(charToRaw(paste0(salt, "", as.character(v))), key = k)
    hex <- substr(paste(as.character(dig), collapse = ""), 1L, nchar_hex)
    paste0(prefix, "-", hex)
  }, character(1), USE.NAMES = FALSE)
}

# --- format-preserving encryption (Feistel) ---------------------------------
# A balanced/alternating Feistel over the symbol domain. Reversible and keyed,
# so an NRIC-shaped input yields an NRIC-shaped token that decrypts back.
# NOTE: this is a self-consistent Feistel FPE, not a NIST-certified FF1/FF3
# implementation; swap in shinyEncrypt's native FF1 if certification is needed.
# Supported when radix^length < 2^53 (true for typical IDs); otherwise callers
# should fall back to se_pseudonymize().

.se_alphabets <- list(
  digits = strsplit("0123456789", "")[[1]],
  alnum_upper = strsplit("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", "")[[1]]
)

.se_fpe_supported <- function(n, radix) {
  is.finite(radix^n) && radix^n < 2^53
}

.se_prf <- function(key, round, tweak, modulus) {
  # HMAC-based round function -> integer in [0, modulus).
  msg <- charToRaw(paste0(tweak, "|", round))
  dig <- openssl::sha256(msg, key = key)
  # take first 6 bytes as a big-ish integer, reduce mod modulus
  bytes <- as.integer(dig[1:6])
  val <- 0
  for (b in bytes) val <- (val * 256 + b)
  val %% modulus
}

.se_str_to_int <- function(syms, alphabet) {
  radix <- length(alphabet)
  idx <- match(syms, alphabet) - 1L
  Reduce(function(acc, d) acc * radix + d, idx, accumulate = FALSE)
}

.se_int_to_str <- function(x, len, alphabet) {
  radix <- length(alphabet)
  out <- integer(len)
  for (i in seq_len(len)) {
    out[len - i + 1L] <- x %% radix
    x <- x %/% radix
  }
  paste(alphabet[out + 1L], collapse = "")
}

.se_feistel <- function(syms, alphabet, key, tweak, rounds = 8L, decrypt = FALSE) {
  radix <- length(alphabet)
  n <- length(syms)
  u <- n %/% 2L
  v <- n - u
  a <- syms[seq_len(u)]
  b <- syms[(u + 1L):n]
  A <- .se_str_to_int(a, alphabet)
  B <- .se_str_to_int(b, alphabet)
  mU <- radix^u
  mV <- radix^v
  rseq <- if (decrypt) rev(seq_len(rounds) - 1L) else (seq_len(rounds) - 1L)
  for (r in rseq) {
    if (r %% 2L == 0L) {
      # transform A using B
      f <- .se_prf(key, r, paste0(tweak, ":", B), mU)
      A <- if (decrypt) ((A - f) %% mU) else ((A + f) %% mU)
    } else {
      f <- .se_prf(key, r, paste0(tweak, ":", A), mV)
      B <- if (decrypt) ((B - f) %% mV) else ((B + f) %% mV)
    }
  }
  paste0(.se_int_to_str(A, u, alphabet), .se_int_to_str(B, v, alphabet))
}

#' Format-preserving encrypt/decrypt of a single token.
#' Non-alphabet characters (dashes, letters in a numeric mode) are held in place.
se_fpe <- function(value, key, mode = c("digits", "alnum_upper"),
                   tweak = "", decrypt = FALSE) {
  mode <- match.arg(mode)
  if (is.na(value)) return(NA_character_)
  alphabet <- .se_alphabets[[mode]]
  chars <- strsplit(as.character(value), "")[[1]]
  if (mode == "alnum_upper") chars <- toupper(chars)
  positions <- which(chars %in% alphabet)
  if (length(positions) < 2L) return(as.character(value)) # nothing to permute
  syms <- chars[positions]
  radix <- length(alphabet)
  k <- se_derive_key(key, paste0("fpe:", mode))
  if (!.se_fpe_supported(length(syms), radix)) {
    return(NA_character_) # signal caller to fall back to pseudonym
  }
  out_syms <- .se_feistel(syms, alphabet, k, tweak, rounds = 8L, decrypt = decrypt)
  out_chars <- chars
  out_chars[positions] <- strsplit(out_syms, "")[[1]]
  paste(out_chars, collapse = "")
}

# --- AEAD crosswalk (authorised re-identification) --------------------------

#' Encrypt an original<->token crosswalk data.frame to a raw blob.
#' Uses libsodium secretbox (XSalsa20-Poly1305) via {sodium}.
se_crosswalk_encrypt <- function(df, key) {
  k <- se_derive_key(key, "crosswalk", size = 32L)
  payload <- serialize(df, connection = NULL)
  nonce <- sodium::random(24L)
  ct <- sodium::data_encrypt(payload, k, nonce)
  list(nonce = nonce, ciphertext = ct)
}

se_crosswalk_decrypt <- function(blob, key) {
  k <- se_derive_key(key, "crosswalk", size = 32L)
  payload <- sodium::data_decrypt(blob$ciphertext, k, blob$nonce)
  unserialize(payload)
}

# --- detached signatures (per-stage "signages") ------------------------------
# ed25519 over {sodium}. A user's signing key is generated once and stored in
# their keystore; the public key travels in the project bundle so a reviewer on
# another machine can verify the de-identifier's signature (signed handoff).

se_sig_keygen <- function() {
  sk <- sodium::sig_keygen()
  list(secret = sk, public = sodium::sig_pubkey(sk))
}

#' Sign an arbitrary R object (canonicalised via serialize).
se_sign <- function(object, secret_key) {
  msg <- serialize(object, connection = NULL)
  sodium::sig_sign(msg, secret_key)
}

se_verify <- function(object, signature, public_key) {
  msg <- serialize(object, connection = NULL)
  tryCatch(sodium::sig_verify(msg, signature, public_key),
           error = function(e) FALSE)
}
