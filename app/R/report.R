# report.R — human-readable de-identification certificate + full report (PDF).
#
# Air-gap safe and dependency-light: rendering uses base R's grDevices `pdf()`
# device only (the standard-14 PDF fonts ship with R), so there is NO pandoc,
# LaTeX, headless browser, or network call anywhere in this path. The same
# machine that runs the app can emit the certificate offline.
#
# Two halves, deliberately split so the content is testable without a device:
#   se_cert_data(proj, paths)  -> a structured list/data.frames of everything
#                                 that belongs on the certificate + report.
#   se_report_pdf(cert, file)  -> paginates that structure onto an A4 PDF.
#
# se_cert_data() is a superset of the legacy certificate.json fields, so the
# JSON certificate written from it stays backward compatible.

# ---- data assembly (pure, no graphics device needed) ------------------------

#' Assemble the certificate + report content from an open project.
#'
#' @param proj  the in-memory project list (rv$proj).
#' @param paths se_project_paths(proj$dir); recomputed if NULL.
#' @return a named list: scalar cert fields + policy / manifest / signatures /
#'         audit data.frames + audit action counts, ready to render or serialise.
se_cert_data <- function(proj, paths = NULL) {
  if (is.null(paths)) paths <- se_project_paths(proj$dir)

  # -- column policy ----------------------------------------------------------
  cols <- proj$policy$columns %||% list()
  if (length(cols)) {
    policy_df <- do.call(rbind, lapply(names(cols), function(cn) {
      s <- cols[[cn]]
      data.frame(column = cn,
                 identifier = s$identifier %||% NA_character_,
                 action = s$action %||% "keep",
                 stringsAsFactors = FALSE)
    }))
  } else {
    policy_df <- data.frame(column = character(0), identifier = character(0),
                            action = character(0), stringsAsFactors = FALSE)
  }
  freetext <- unlist(proj$policy$freetext_columns %||% character(0))

  # -- manifest ---------------------------------------------------------------
  manifest_df <- data.frame(file = character(0), role = character(0),
                            bytes = character(0), sha256 = character(0),
                            stringsAsFactors = FALSE)
  if (file.exists(paths$manifest)) {
    man <- tryCatch(jsonlite::fromJSON(paths$manifest), error = function(e) NULL)
    ent <- man$entries
    if (length(ent) && NROW(ent)) {
      manifest_df <- data.frame(
        file   = as.character(ent$file),
        role   = as.character(ent$role),
        bytes  = format(as.integer(ent$bytes), big.mark = ",", scientific = FALSE),
        sha256 = paste0(substr(as.character(ent$sha256), 1, 16), "..."),
        stringsAsFactors = FALSE)
    }
  }

  # -- audit trail + chain verification --------------------------------------
  audit_ver <- se_audit_verify(paths$audit)
  audit_df  <- se_audit_read(paths$audit)
  if (!nrow(audit_df)) {
    audit_df <- data.frame(ts = character(0), action = character(0),
                           actor = character(0), detail = character(0),
                           hash = character(0), stringsAsFactors = FALSE)
  }
  if (nrow(audit_df)) {
    tab <- sort(table(audit_df$action), decreasing = TRUE)
    audit_counts <- data.frame(action = names(tab),
                               count = as.integer(tab),
                               stringsAsFactors = FALSE)
  } else {
    audit_counts <- data.frame(action = character(0), count = integer(0),
                               stringsAsFactors = FALSE)
  }
  sdc_actions <- audit_counts[grepl("^sdc", audit_counts$action), , drop = FALSE]

  # -- signatures (verify each detached signature) ---------------------------
  sig_df <- data.frame(role = character(0), actor = character(0),
                       stage = character(0), when = character(0),
                       verified = character(0), stringsAsFactors = FALSE)
  if (dir.exists(paths$signatures)) {
    sfiles <- list.files(paths$signatures, pattern = "\\.sig\\.rds$",
                         full.names = TRUE)
    if (length(sfiles)) {
      rows <- lapply(sfiles, function(f) {
        s <- tryCatch(readRDS(f), error = function(e) NULL)
        if (is.null(s)) return(NULL)
        ok <- tryCatch(se_verify(s$payload, s$signature, s$public),
                       error = function(e) FALSE)
        data.frame(role = s$payload$role %||% NA_character_,
                   actor = s$payload$actor %||% NA_character_,
                   stage = s$payload$stage %||% NA_character_,
                   when  = s$payload$when %||% NA_character_,
                   verified = if (isTRUE(ok)) "verified" else "FAILED",
                   stringsAsFactors = FALSE)
      })
      rows <- rows[!vapply(rows, is.null, logical(1))]
      if (length(rows)) sig_df <- do.call(rbind, rows)
    }
  }

  list(
    title       = "De-identification Certificate & Report",
    org         = "Structured De-identification System",
    project     = proj$name %||% "(unnamed project)",
    generated   = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    hash_scope  = proj$hash_scope %||% "project",
    stage       = proj$stage %||% "created",
    policy_columns  = nrow(policy_df),
    freetext_columns = freetext,
    manifest_sha256 = if (file.exists(paths$manifest)) se_sha256_file(paths$manifest) else NA_character_,
    audit       = audit_ver,
    policy_df   = policy_df,
    manifest_df = manifest_df,
    audit_df    = audit_df,
    audit_counts = audit_counts,
    sdc_actions = sdc_actions,
    signatures_df = sig_df,
    frameworks  = c("PDPA (Personal Data Protection Act, Singapore)",
                    "HIPAA Safe Harbor (reference standard)",
                    "SingHealth / IRB governance"),
    disclaimer  = paste(
      "Not for clinical or diagnostic use. This certificate records the",
      "de-identification process applied to the listed inputs; it is not a",
      "guarantee of anonymity. The data controller remains responsible for",
      "confirming the adequacy of de-identification against the applicable",
      "legal and institutional framework before any release of the data.")
  )
}

# ---- low-level paginated layout on the base pdf() device --------------------
# A cursor-based renderer. State lives in an environment (`st`) so helpers
# mutate the y-cursor / page counter in place. User coordinates == inches
# (mar=0, xaxs/yaxs="i"), so strwidth/strheight in "user" units are inches.

.se_rpt_state <- function(pw, ph) {
  e <- new.env(parent = emptyenv())
  e$pw <- pw; e$ph <- ph
  e$ml <- 0.9; e$mr <- 0.9; e$mt <- 0.95; e$mb <- 0.80
  e$cw <- pw - e$ml - e$mr
  e$x  <- e$ml
  e$y  <- ph - e$mt
  e$page <- 0L
  e$footer_left <- ""
  e
}

.se_lh <- function(cex) strheight("Ag", cex = cex, units = "user") * 1.5

.se_footer <- function(st) {
  text(st$ml, st$mb * 0.55, st$footer_left, adj = c(0, 0.5),
       cex = 0.60, col = "grey45")
  text(st$pw - st$mr, st$mb * 0.55, paste("Page", st$page), adj = c(1, 0.5),
       cex = 0.60, col = "grey45")
  lines(c(st$ml, st$pw - st$mr), rep(st$mb * 0.9, 2), col = "grey85", lwd = 0.7)
}

.se_new_page <- function(st) {
  st$page <- st$page + 1L
  par(mar = c(0, 0, 0, 0), xaxs = "i", yaxs = "i")
  plot.new()
  plot.window(xlim = c(0, st$pw), ylim = c(0, st$ph))
  st$y <- st$ph - st$mt
  .se_footer(st)
  invisible(st)
}

.se_need <- function(st, h) {
  if (st$y - h < st$mb + 0.15) .se_new_page(st)
  invisible(st)
}

.se_wrap <- function(text, cex, width, font = 1) {
  text <- gsub("\r", "", as.character(text %||% ""))
  if (!length(text)) return("")
  paras <- strsplit(text, "\n", fixed = TRUE)[[1]]
  if (!length(paras)) paras <- ""
  out <- character(0)
  for (p in paras) {
    words <- strsplit(p, "\\s+")[[1]]
    words <- words[nzchar(words)]
    if (!length(words)) { out <- c(out, ""); next }
    line <- words[1]
    for (w in words[-1]) {
      test <- paste(line, w)
      if (strwidth(test, units = "user", cex = cex, font = font) <= width)
        line <- test
      else { out <- c(out, line); line <- w }
    }
    out <- c(out, line)
  }
  out
}

.se_gap <- function(st, inch) { st$y <- st$y - inch; invisible(st) }

.se_heading <- function(st, text, level = 1) {
  cex <- if (level == 1) 1.15 else 0.98
  lh  <- .se_lh(cex)
  .se_gap(st, if (level == 1) 0.22 else 0.16)
  .se_need(st, lh + 0.1)
  graphics::text(st$ml, st$y, text, adj = c(0, 1), cex = cex, font = 2,
                 col = if (level == 1) "grey15" else "grey25")
  st$y <- st$y - lh
  if (level == 1) {
    lines(c(st$ml, st$pw - st$mr), rep(st$y + lh * 0.30, 2),
          col = "grey70", lwd = 0.9)
    st$y <- st$y - 0.06
  }
  invisible(st)
}

.se_para <- function(st, text, cex = 0.80, col = "grey20") {
  lines_ <- .se_wrap(text, cex, st$cw)
  lh <- .se_lh(cex)
  for (ln in lines_) {
    .se_need(st, lh)
    graphics::text(st$ml, st$y, ln, adj = c(0, 1), cex = cex, col = col)
    st$y <- st$y - lh
  }
  .se_gap(st, lh * 0.2)
  invisible(st)
}

.se_bullets <- function(st, items, cex = 0.80) {
  lh <- .se_lh(cex)
  for (it in items) {
    wl <- .se_wrap(it, cex, st$cw - 0.25)
    for (i in seq_along(wl)) {
      .se_need(st, lh)
      # Vector marker (pch=15), not a "•" glyph, so no Symbol-font dependency
      # on a locked-down target.
      if (i == 1) graphics::points(st$ml + 0.09, st$y - lh * 0.30, pch = 15,
                                   cex = cex * 0.5, col = "grey35")
      graphics::text(st$ml + 0.25, st$y, wl[i], adj = c(0, 1), cex = cex, col = "grey20")
      st$y <- st$y - lh
    }
  }
  .se_gap(st, lh * 0.2)
  invisible(st)
}

.se_kv <- function(st, key, value, cex = 0.80) {
  keyw <- 2.05
  valw <- st$cw - keyw
  vlines <- .se_wrap(value, cex, valw)
  lh <- .se_lh(cex)
  .se_need(st, lh * length(vlines))
  ytop <- st$y
  graphics::text(st$ml, ytop, key, adj = c(0, 1), cex = cex, font = 2, col = "grey25")
  for (i in seq_along(vlines)) {
    graphics::text(st$ml + keyw, st$y, vlines[i], adj = c(0, 1), cex = cex, col = "grey15")
    st$y <- st$y - lh
  }
  .se_gap(st, lh * 0.12)
  invisible(st)
}

.se_table <- function(st, df, widths = NULL, cex = 0.72) {
  ncols <- ncol(df); nm <- names(df); pad <- 0.06
  if (is.null(widths)) widths <- rep(1, ncols)
  colw <- widths / sum(widths) * st$cw
  colx <- st$ml + c(0, cumsum(colw))[seq_len(ncols)]
  lh <- .se_lh(cex)

  draw_header <- function() {
    .se_need(st, lh * 1.6)
    graphics::text(colx + pad, rep(st$y, ncols), nm, adj = c(0, 1),
                   cex = cex, font = 2, col = "grey25")
    st$y <- st$y - lh
    lines(c(st$ml, st$ml + st$cw), rep(st$y + lh * 0.18, 2),
          col = "grey60", lwd = 0.8)
    st$y <- st$y - lh * 0.12
  }

  draw_header()
  if (!nrow(df)) { .se_para(st, "(none)", cex = cex, col = "grey45"); return(invisible(st)) }

  for (r in seq_len(nrow(df))) {
    cells <- lapply(seq_len(ncols), function(j)
      .se_wrap(as.character(df[r, j]), cex, colw[j] - 2 * pad))
    rh <- max(vapply(cells, length, 1L)) * lh + lh * 0.28
    if (st$y - rh < st$mb + 0.15) { .se_new_page(st); draw_header() }
    ytop <- st$y
    for (j in seq_len(ncols)) {
      yy <- ytop
      for (ln in cells[[j]]) {
        graphics::text(colx[j] + pad, yy, ln, adj = c(0, 1), cex = cex, col = "grey15")
        yy <- yy - lh
      }
    }
    st$y <- ytop - rh
    lines(c(st$ml, st$ml + st$cw), rep(st$y + lh * 0.12, 2),
          col = "grey90", lwd = 0.5)
  }
  .se_gap(st, lh * 0.2)
  invisible(st)
}

.se_disclaimer_box <- function(st, text, cex = 0.72) {
  inner <- st$cw - 0.3
  wl <- .se_wrap(text, cex, inner)
  lh <- .se_lh(cex)
  boxh <- length(wl) * lh + 0.28
  .se_gap(st, 0.15)
  .se_need(st, boxh + 0.1)
  ytop <- st$y
  rect(st$ml, ytop - boxh, st$ml + st$cw, ytop,
       border = "grey55", col = "grey96", lwd = 0.8)
  yy <- ytop - 0.14
  for (ln in wl) {
    graphics::text(st$ml + 0.15, yy, ln, adj = c(0, 1), cex = cex, col = "grey20")
    yy <- yy - lh
  }
  st$y <- ytop - boxh
  invisible(st)
}

.se_title_block <- function(st, cert) {
  graphics::text(st$ml, st$y, cert$org, adj = c(0, 1), cex = 0.78,
                 font = 2, col = "grey45")
  st$y <- st$y - .se_lh(0.78) * 0.9
  graphics::text(st$ml, st$y, cert$title, adj = c(0, 1), cex = 1.7,
                 font = 2, col = "grey10")
  st$y <- st$y - .se_lh(1.7)
  lines(c(st$ml, st$pw - st$mr), rep(st$y + 0.10, 2), col = "grey30", lwd = 1.4)
  st$y <- st$y - 0.12
  chain <- if (isTRUE(cert$audit$ok))
    sprintf("intact (%d entries)", cert$audit$n %||% 0L)
  else sprintf("BROKEN at entry %s", cert$audit$broken_at %||% NA)
  sub <- sprintf("Project: %s     Generated: %s     Audit chain: %s",
                 cert$project, cert$generated, chain)
  graphics::text(st$ml, st$y, sub, adj = c(0, 1), cex = 0.72, col = "grey35")
  st$y <- st$y - .se_lh(0.72)
  invisible(st)
}

# ---- top-level: render the certificate + report to a PDF file ---------------

#' Render the assembled certificate/report to a paginated A4 PDF.
#' @param cert output of se_cert_data().
#' @param file destination path.
#' @return `file`, invisibly.
se_report_pdf <- function(cert, file) {
  grDevices::pdf(file, width = 8.27, height = 11.69, pointsize = 11,
                 title = "De-identification Certificate")
  on.exit(grDevices::dev.off(), add = TRUE)

  st <- .se_rpt_state(8.27, 11.69)
  st$footer_left <- sprintf("%s - %s", cert$org, cert$project)
  .se_new_page(st)
  .se_title_block(st, cert)

  # 1. Certificate summary
  .se_heading(st, "Certificate summary", 1)
  .se_kv(st, "Project", cert$project)
  .se_kv(st, "Generated", cert$generated)
  .se_kv(st, "Workflow stage", cert$stage)
  .se_kv(st, "Hashing scope", cert$hash_scope)
  .se_kv(st, "Policy columns", as.character(cert$policy_columns))
  .se_kv(st, "Free-text columns",
         if (length(cert$freetext_columns)) paste(cert$freetext_columns, collapse = ", ") else "(none)")
  .se_kv(st, "Manifest SHA-256", cert$manifest_sha256 %||% "(no manifest)")
  .se_kv(st, "Audit chain",
         if (isTRUE(cert$audit$ok)) sprintf("intact - %d entries", cert$audit$n %||% 0L)
         else sprintf("BROKEN at entry %s of %s", cert$audit$broken_at, cert$audit$n))
  nsig <- nrow(cert$signatures_df)
  nver <- sum(cert$signatures_df$verified == "verified")
  .se_kv(st, "Signatures", sprintf("%d present, %d verified", nsig, nver))

  # 2. Compliance frameworks
  .se_heading(st, "Governance & compliance", 1)
  .se_para(st, paste("This de-identification was carried out with reference to",
                     "the following frameworks. Citation indicates the process",
                     "was designed against these standards; it does not by",
                     "itself certify legal compliance."))
  .se_bullets(st, cert$frameworks)

  # 3. Column policy
  .se_heading(st, "Column de-identification policy", 1)
  .se_table(st, cert$policy_df, widths = c(1.2, 1.3, 1.0))

  # 4. Manifest
  .se_heading(st, "File manifest (SHA-256)", 1)
  .se_table(st, cert$manifest_df, widths = c(1.7, 0.7, 0.7, 1.4))

  # 5. Signatures
  .se_heading(st, "Signatures", 1)
  .se_table(st, cert$signatures_df, widths = c(0.9, 1.0, 0.9, 1.3, 0.8))

  # 6. Audit trail
  .se_heading(st, "Audit summary", 1)
  chain_txt <- if (isTRUE(cert$audit$ok))
    sprintf("The tamper-evident hash chain is intact across all %d entries.",
            cert$audit$n %||% 0L)
  else sprintf("WARNING: the hash chain is BROKEN at entry %s - the audit log has been altered.",
               cert$audit$broken_at)
  .se_para(st, chain_txt)
  .se_table(st, cert$audit_counts, widths = c(2.4, 0.8))

  if (nrow(cert$sdc_actions)) {
    .se_heading(st, "Statistical disclosure control", 2)
    .se_para(st, paste("Opt-in disclosure-control actions were recorded for this",
                       "project (see the audit trail below for detail):"))
    .se_table(st, cert$sdc_actions, widths = c(2.4, 0.8))
  }

  .se_heading(st, "Full audit trail", 2)
  .se_table(st, cert$audit_df[, c("ts", "action", "actor", "hash")],
            widths = c(1.5, 1.1, 1.0, 0.8))

  # 7. Disclaimer
  .se_heading(st, "Disclaimer", 1)
  .se_disclaimer_box(st, cert$disclaimer)

  invisible(file)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
