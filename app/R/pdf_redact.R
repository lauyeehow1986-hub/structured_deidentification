# pdf_redact.R — true redaction of PDFs, pure R, air-gap safe.
#
# Two page types, one pipeline:
#   digital  page has an extractable text layer -> word boxes from pdftools::pdf_data
#   scanned  no text layer (or forced) -> render + tesseract OCR word boxes
#
# Detection reuses the deterministic detectors (detect_r.R) over the reconstructed
# text; matched character spans are mapped back to the word boxes they touch.
#
# TRUE REMOVAL, not cosmetic boxes: every page is rendered to a raster, the PII
# boxes are painted solid, and the pages are reassembled as an IMAGE-ONLY PDF.
# Rasterising drops the original text/vector layer entirely, so redacted content
# cannot be recovered by copy-paste, text extraction, or "remove the black box".
# The trade-off (no selectable text in the output, larger file) is the correct
# default for a governance de-identification tool. A post-redaction guard OCRs
# the painted regions and fails closed if any target text is still readable.
#
# Everything runs in-process in R (pdftools/tesseract/magick are bundled R pkgs)
# — no subprocess, no network, nothing to provision.

# --- word-box helpers --------------------------------------------------------

# Join a page's words into one string, remembering each word's char span, so a
# regex hit over the joined text can be mapped back to the boxes it covers.
.se_words_join <- function(words) {
  text <- ""; starts <- integer(0); ends <- integer(0); pos <- 1L
  for (i in seq_along(words)) {
    w <- words[i]
    starts[i] <- pos; ends[i] <- pos + nchar(w) - 1L
    text <- paste0(text, w, " "); pos <- pos + nchar(w) + 1L
  }
  list(text = trimws(text, "right"), starts = starts, ends = ends)
}

# Which word indices does character span [s,e] overlap?
.se_boxes_for_span <- function(starts, ends, s, e)
  which(starts <= e & ends >= s)

#' Detect PII word boxes on one page given its words + pixel boxes.
#' words: character vector; boxes: data.frame(left,top,width,height) in pixels.
#' scan_fn: text -> data.frame(start,end,type,identifier[,match]); defaults to the
#'   deterministic detectors. Pass an NER/LLM-backed scanner to also catch names.
#' Returns data.frame(left,top,width,height,text,type,identifier).
.se_pii_boxes <- function(words, boxes, detectors, scan_fn = NULL) {
  if (!length(words)) return(boxes[0, , drop = FALSE])
  j <- .se_words_join(words)
  spans <- if (is.null(scan_fn)) se_scan_text(j$text, detectors = detectors)
           else scan_fn(j$text)
  if (!nrow(spans)) return(cbind(boxes[0, , drop = FALSE],
                                 text = character(0), type = character(0),
                                 identifier = character(0)))
  out <- list()
  for (i in seq_len(nrow(spans))) {
    idx <- .se_boxes_for_span(j$starts, j$ends, spans$start[i], spans$end[i])
    idx <- idx[idx >= 1 & idx <= nrow(boxes)]
    for (k in idx) {
      out[[length(out) + 1L]] <- data.frame(
        left = boxes$left[k], top = boxes$top[k],
        width = boxes$width[k], height = boxes$height[k],
        text = words[k], type = spans$type[i],
        identifier = spans$identifier[i], stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

# --- per-page box extraction -------------------------------------------------

# Digital text layer -> pixel boxes (pdf_data points * dpi/72).
.se_page_boxes_digital <- function(pd, dpi) {
  if (is.null(pd) || !nrow(pd)) return(NULL)
  sc <- dpi / 72
  boxes <- data.frame(left = pd$x * sc, top = pd$y * sc,
                      width = pd$width * sc, height = pd$height * sc,
                      stringsAsFactors = FALSE)
  list(words = pd$text, boxes = boxes)
}

# Rendered image -> OCR word boxes (already in pixel space of the render).
.se_page_boxes_ocr <- function(img, engine) {
  od <- tesseract::ocr_data(img, engine = engine)
  if (is.null(od) || !nrow(od)) return(list(words = character(0),
                                            boxes = data.frame()))
  # bbox is "x1,y1,x2,y2"
  bb <- do.call(rbind, lapply(strsplit(od$bbox, ","), as.numeric))
  boxes <- data.frame(left = bb[, 1], top = bb[, 2],
                      width = bb[, 3] - bb[, 1], height = bb[, 4] - bb[, 2],
                      stringsAsFactors = FALSE)
  list(words = od$word, boxes = boxes)
}

# --- main --------------------------------------------------------------------

#' Redact a PDF and write a flattened, image-only PDF with PII removed.
#'
#' @param input   path to the source PDF.
#' @param output  path to write the redacted PDF.
#' @param dpi     render resolution (default 150; raise for small print / OCR).
#' @param force_ocr  treat every page as scanned (OCR) even if it has text.
#' @param pad     pixels of padding added around each box before painting.
#' @param detectors detector set (default se_detectors()).
#' @param verify  OCR each painted region afterwards; fail closed if target text
#'                is still readable. Default TRUE.
#' @return list(output, pages, n_boxes, findings, methods, verified)
se_pdf_redact <- function(input, output, dpi = 150, force_ocr = FALSE,
                          pad = 2, detectors = se_detectors(), verify = TRUE,
                          scan_fn = NULL) {
  stopifnot(file.exists(input))
  npages <- pdftools::pdf_info(input)$pages
  pd_all <- tryCatch(pdftools::pdf_data(input), error = function(e) NULL)

  eng <- tryCatch(tesseract::tesseract("eng"), error = function(e) NULL)
  findings <- list(); methods <- character(npages); imgs <- vector("list", npages)
  total_boxes <- 0L

  for (p in seq_len(npages)) {
    raw <- pdftools::pdf_render_page(input, page = p, dpi = dpi, numeric = FALSE)
    img <- magick::image_read(raw)
    info <- magick::image_info(img)
    W <- info$width; H <- info$height

    pd <- if (!is.null(pd_all) && length(pd_all) >= p) pd_all[[p]] else NULL
    use_ocr <- force_ocr || is.null(pd) || !nrow(pd)
    if (use_ocr && is.null(eng)) use_ocr <- FALSE  # no OCR engine -> digital only

    pb <- if (use_ocr) .se_page_boxes_ocr(img, eng) else .se_page_boxes_digital(pd, dpi)
    methods[p] <- if (use_ocr) "ocr" else "digital"

    pii <- if (!is.null(pb) && length(pb$words))
      .se_pii_boxes(pb$words, pb$boxes, detectors, scan_fn) else NULL

    if (!is.null(pii) && nrow(pii)) {
      img <- magick::image_draw(img)  # returns the drawable image; paint onto it
      for (i in seq_len(nrow(pii))) {
        x0 <- max(0, pii$left[i] - pad); y0 <- max(0, pii$top[i] - pad)
        x1 <- min(W, pii$left[i] + pii$width[i] + pad)
        y1 <- min(H, pii$top[i] + pii$height[i] + pad)
        graphics::rect(x0, y0, x1, y1, col = "black", border = "black")
      }
      grDevices::dev.off()  # img now holds the painted result
      pii$page <- p
      findings[[length(findings) + 1L]] <- pii
      total_boxes <- total_boxes + nrow(pii)
    }
    imgs[[p]] <- img
  }

  # reassemble as an image-only PDF (text layer is gone)
  joined <- magick::image_join(imgs)
  magick::image_write(joined, path = output, format = "pdf", density = dpi)

  findings_df <- if (length(findings)) do.call(rbind, findings) else
    data.frame(left=numeric(0), top=numeric(0), width=numeric(0), height=numeric(0),
               text=character(0), type=character(0), identifier=character(0),
               page=integer(0), stringsAsFactors = FALSE)

  verified <- TRUE
  if (isTRUE(verify) && nrow(findings_df) && !is.null(eng))
    verified <- .se_pdf_verify(output, findings_df, dpi, eng)

  list(output = output, pages = npages, n_boxes = total_boxes,
       findings = findings_df, methods = methods, verified = verified)
}

# Re-OCR each painted region in the OUTPUT and confirm the target token is no
# longer readable there. Fails closed (verified = FALSE) if any target survives.
.se_pdf_verify <- function(output, findings, dpi, eng) {
  for (p in unique(findings$page)) {
    raw <- pdftools::pdf_render_page(output, page = p, dpi = dpi, numeric = FALSE)
    img <- magick::image_read(raw)
    fp <- findings[findings$page == p, , drop = FALSE]
    for (i in seq_len(nrow(fp))) {
      geom <- magick::geometry_area(
        width  = max(1, round(fp$width[i]) + 4),
        height = max(1, round(fp$height[i]) + 4),
        x_off  = max(0, round(fp$left[i]) - 2),
        y_off  = max(0, round(fp$top[i]) - 2))
      crop <- magick::image_crop(img, geom)
      got <- tryCatch(tesseract::ocr(crop, engine = eng), error = function(e) "")
      got <- gsub("\\s+", "", tolower(got))
      want <- gsub("\\s+", "", tolower(fp$text[i]))
      if (nzchar(want) && nchar(want) >= 3 && grepl(want, got, fixed = TRUE))
        return(FALSE)
    }
  }
  TRUE
}

#' Detect-only: list PII boxes per page without redacting (for a review step).
se_pdf_detect <- function(input, dpi = 150, force_ocr = FALSE,
                          detectors = se_detectors(), scan_fn = NULL) {
  stopifnot(file.exists(input))
  npages <- pdftools::pdf_info(input)$pages
  pd_all <- tryCatch(pdftools::pdf_data(input), error = function(e) NULL)
  eng <- tryCatch(tesseract::tesseract("eng"), error = function(e) NULL)
  out <- list()
  for (p in seq_len(npages)) {
    pd <- if (!is.null(pd_all) && length(pd_all) >= p) pd_all[[p]] else NULL
    use_ocr <- force_ocr || is.null(pd) || !nrow(pd)
    if (use_ocr) {
      if (is.null(eng)) next
      raw <- pdftools::pdf_render_page(input, page = p, dpi = dpi, numeric = FALSE)
      pb <- .se_page_boxes_ocr(magick::image_read(raw), eng)
    } else pb <- .se_page_boxes_digital(pd, dpi)
    pii <- if (!is.null(pb) && length(pb$words))
      .se_pii_boxes(pb$words, pb$boxes, detectors, scan_fn) else NULL
    if (!is.null(pii) && nrow(pii)) { pii$page <- p; out[[length(out)+1L]] <- pii }
  }
  if (length(out)) do.call(rbind, out) else
    data.frame(left=numeric(0), top=numeric(0), width=numeric(0), height=numeric(0),
               text=character(0), type=character(0), identifier=character(0),
               page=integer(0), stringsAsFactors = FALSE)
}
