# app.R — Structured De-identification System (Shiny UI).
# Launch from the bundle root:  shiny::runApp("app")
# or via the portable launcher (run.bat / run.ps1).

local({
  cand <- c("global.R", file.path("app", "global.R"))
  hit <- cand[file.exists(cand)][1]
  if (is.na(hit)) stop("cannot locate global.R")
  source(hit, local = FALSE)
})

# ---- small UI helpers -------------------------------------------------------

se_read_table <- function(path, sheet = NULL) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("xlsx", "xls")) {
    df <- as.data.frame(readxl::read_excel(path, sheet = sheet %||% 1,
                                           col_types = "text"))
  } else {
    df <- utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
                          check.names = FALSE, na.strings = c("NA"))
  }
  df
}

# heuristic column -> identifier suggestion from name + content
se_suggest_mapping <- function(df) {
  prof <- se_profile_table(df)
  name_hint <- function(cn) {
    x <- tolower(cn)
    if (grepl("name|alias|initial", x)) return("name")
    if (grepl("nric|\\bfin\\b|passport|birth\\s*cert|national.?id", x)) return("national_id")
    if (grepl("mrn|medical.?record|record.?no|hosp.?no|patient.?id", x)) return("mrn")
    if (grepl("case|visit|episode|admission|encounter|billing", x)) return("case_visit")
    if (grepl("fax", x)) return("fax")
    if (grepl("phone|tel|mobile|hp\\b|contact|pager", x)) return("phone")
    if (grepl("email|e-?mail", x)) return("email")
    if (grepl("postal|zip", x)) return("postal_code")
    if (grepl("address|addr|street|block|unit|residen", x)) return("address")
    if (grepl("death|deceas|expir|demise", x)) return("date_of_death")
    if (grepl("dob|birth|\\bbday\\b", x)) return("dob")
    if (grepl("serial|device|\\bsn\\b|implant", x)) return("device")
    if (grepl("biometric|fingerprint|iris|voiceprint", x)) return("biometric")
    if (grepl("photo|image|face|picture|img", x)) return("photo")
    if (grepl("note|remark|comment|free|text|desc|diagnos", x)) return("other_id")
    NA_character_
  }
  out <- list()
  for (cn in names(df)) {
    ident <- name_hint(cn)
    if (is.na(ident)) {
      dt <- prof$per_column[[cn]]$dominant_type
      ident <- switch(dt %||% "", nric="national_id", email="email", phone="phone",
                      postal="postal_code", date="dob", mrn="mrn", "keep")
      if (identical(ident, "keep")) ident <- NA_character_
    }
    out[[cn]] <- ident
  }
  list(mapping = out, profile = prof)
}

# ---- UI ---------------------------------------------------------------------

ui <- page_navbar(
  title = "Structured De-identification",
  theme = bs_theme(version = 5, preset = "flatly"),
  id = "nav",
  sidebar = sidebar(
    width = 300,
    selectInput("role", "Your role",
                c("De-identifier" = "deidentifier", "Reviewer" = "reviewer")),
    textInput("actor", "Your name / ID", value = Sys.getenv("USERNAME", "operator")),
    hr(),
    uiOutput("proj_status"),
    hr(),
    div(class = "small text-muted",
        "Educational / research de-identification tool. Not for clinical or ",
        "diagnostic use. Verify every output before release.")
  ),

  # 1. PROJECT
  nav_panel("1 · Project", icon = icon("folder-open"),
    layout_columns(col_widths = c(6, 6),
      card(card_header("Open or create a project folder"),
        textInput("proj_dir", "Project folder (on the data drive)",
                  placeholder = "e.g. D:/deid_projects/StudyA", width = "100%"),
        textInput("proj_name", "Project name", value = "StudyA"),
        radioButtons("hash_scope", "Default hashing scope",
          c("Project-specific key (isolated)" = "project",
            "Global key (link across projects)" = "global")),
        div(actionButton("btn_create", "Create", class = "btn-primary"),
            actionButton("btn_open", "Open existing"))),
      card(card_header("What lives in the project folder"),
        tags$ul(
          tags$li(tags$b("project.json"), " — settings, identifier policy, state"),
          tags$li(tags$b("inputs/ · outputs/"), " — source and de-identified files"),
          tags$li(tags$b("work/"), " — checkpoints for resume + parallel"),
          tags$li(tags$b("crosswalk.enc"), " — encrypted re-identification map"),
          tags$li(tags$b("manifest.json"), " — SHA-256 of every file"),
          tags$li(tags$b("audit.log"), " — tamper-evident action log"),
          tags$li(tags$b("signatures/ · certificate.json"), " — signed sign-off")),
        div(class="small text-muted",
            "The whole folder is portable: unplug the drive and resume on any ",
            "machine running this tool."))
    )
  ),

  # 2. IMPORT
  nav_panel("2 · Import", icon = icon("file-import"),
    card(card_header("Load a table (CSV / XLSX)"),
      fileInput("file", NULL, accept = c(".csv", ".xlsx", ".xls"), width = "100%"),
      uiOutput("sheet_ui"),
      textOutput("import_info")),
    card(card_header("Preview"), DTOutput("preview"))
  ),

  # 3. DETECT & REVIEW
  nav_panel("3 · Detect", icon = icon("magnifying-glass"),
    card(card_header("Run detection"),
      div(actionButton("btn_detect", "Scan for PII + misplaced values",
                       class = "btn-primary"),
          actionButton("btn_enable_ner", "Enable offline NER",
                       class = "btn-outline-secondary ms-2"),
          span(textOutput("py_status", inline = TRUE), class = "text-muted ms-3")),
      div(class = "mt-2",
        checkboxInput("use_pf",
          "Enable Privacy Filter (free-text PII) — recommended", value = TRUE),
        sliderInput("ft_min_conf", "Redaction confidence threshold",
          min = 0.1, max = 0.99, value = 0.5, step = 0.05),
        # Types are the detector `type` vocabulary (detect_r.R) UNION the PF types
        # (name, address, secret). ALL selected by default so nothing is silently
        # left un-redacted; UNCHECK a type to stop redacting it.
        checkboxGroupInput("ft_types", "Redact these free-text types",
          choices = c("name","address","email","phone","date","postal",
                      "nric","passport","mrn","ip","url","account","secret"),
          selected = c("name","address","email","phone","date","postal",
                       "nric","passport","mrn","ip","url","account","secret"),
          inline = TRUE),
        tags$details(tags$summary("Advanced / optional backends"),
          checkboxInput("use_ner",
            "Use Presidio/spaCy NER (needs the separately-bundled model)", value = FALSE),
          checkboxInput("use_llm",
            "Use a local LLM (llama.cpp / Ollama) — off by default", value = FALSE))),
      div(class="small text-muted mt-1",
          "Rules + validators (NRIC checksum, phone, email, dates) and column ",
          "profiling always run with zero Python. Offline NER and the local LLM ",
          "run only against the bundled, on-disk engine. The LLM defaults to a ",
          "socket-free bundled llama.cpp model (no network at all); a local ",
          "Ollama on THIS machine is an alternative. Nothing is ever sent over ",
          "the network. Click Enable offline NER once per session to probe the ",
          "bundled interpreter (never auto-provisioned).")),
    layout_columns(col_widths = c(12),
      card(card_header("Misplaced / outlier values (review these first)"),
        DTOutput("outliers")),
      card(card_header("Free-text PII found in notes-like columns"),
        div(class = "small text-muted mb-1",
            "Select any row to EXCLUDE that value from redaction (reject). ",
            "Everything shown at or above the confidence threshold, and of a ",
            "selected type, will be redacted; the reviewer sees the diff before release."),
        DTOutput("freetext_findings")))
  ),

  # 4. POLICY
  nav_panel("4 · Policy", icon = icon("sliders"),
    card(card_header("Per-column de-identification policy"),
      div(actionButton("btn_autosuggest", "Auto-suggest mapping"),
          actionButton("btn_save_policy", "Save policy", class = "btn-primary")),
      div(class = "mt-2 p-2 border rounded",
        tags$b("Date handling (applies to columns whose action is Generalize on a date/DOB)"),
        selectInput("date_method", "Date generalise method",
          c("Year only" = "year", "Year-month (drop day)" = "year_month",
            "Date-shift (keep intervals)" = "date_shift"), selected = "year"),
        numericInput("shift_window", "Date-shift window (± days)", value = 365, min = 1),
        selectInput("shift_subject_col", "Date-shift subject column (optional)",
          choices = c("(dataset-wide)" = ""), selected = "")),
      div(class="small text-muted mt-2",
          "Pick the identifier and action for each column. FPE is optional; ",
          "the default for IDs is a keyed pseudonym token."),
      uiOutput("policy_ui"))
  ),

  # 5. DE-IDENTIFY
  nav_panel("5 · De-identify", icon = icon("user-secret"),
    card(card_header("Apply the policy"),
      radioButtons("out_format", "Output format", c("CSV"="csv","XLSX"="xlsx"),
                   inline = TRUE),
      layout_columns(col_widths = c(4, 4, 4),
        numericInput("chunk_size", "Rows per chunk", value = 50000,
                     min = 100, step = 1000),
        checkboxInput("parallel", "Run chunks in parallel", value = FALSE),
        numericInput("workers", "Parallel workers", value = 2, min = 1,
                     step = 1)),
      actionButton("btn_deid", "Run de-identification", class = "btn-primary"),
      div(class="small text-muted mt-2",
          "Requires the De-identifier role. Large files are processed in ",
          "checkpointed chunks under work/, so a killed run — or the drive ",
          "moved to another machine — resumes where it stopped. Writes to ",
          "outputs/, records the encrypted crosswalk, manifest and audit entry."),
      verbatimTextOutput("deid_resume"),
      verbatimTextOutput("deid_summary"))
  ),

  # 6. REVIEW OUTPUT
  nav_panel("6 · Review output", icon = icon("table-columns"),
    card(card_header("Original vs de-identified (side by side)"),
      uiOutput("review_controls"), DTOutput("review_table")),
    card(card_header("Reviewer decision"),
      div(actionButton("btn_approve", "Approve", class="btn-success"),
          actionButton("btn_return", "Return to de-identifier", class="btn-warning")),
      div(class="small text-muted mt-2", "Reviewer role only."))
  ),

  # 7. SDC
  nav_panel("7 · Disclosure control", icon = icon("shield-halved"),
    card(card_header("Statistical disclosure control (all optional)"),
      uiOutput("sdc_quasi_ui"),
      checkboxGroupInput("sdc_steps", "Measures to run",
        c("k-anonymity" = "kanon", "l-diversity" = "ldiv",
          "Sample uniques (SUDA-lite)" = "suda",
          "Individual risk (sdcMicro)" = "risk",
          "Linkage risk DCR vs original" = "dcr"),
        selected = c("kanon")),
      numericInput("sdc_k", "Target k", value = 5, min = 2, width = "150px"),
      actionButton("btn_sdc", "Run selected measures", class = "btn-primary"),
      div(class = "small text-muted mt-1",
          "Measures (and the export gate) run on the treated table once you apply transforms below."),
      verbatimTextOutput("sdc_out")),

    card(card_header("Risk-reduction transforms (opt-in)"),
      p(class = "small text-muted",
        "Coarsen or perturb the quasi-identifiers to raise k / cut uniques, at a stated ",
        "cost to utility. Preview shows the effect on k before you commit; Apply stacks the ",
        "transform onto a treated copy. Transforms act on the working table (a bounded sample ",
        "when the output is large — analysis-only in that case)."),
      layout_columns(col_widths = c(4, 8),
        selectInput("sdc_tx", "Transform",
          c("Local suppression (force k)" = "suppress",
            "Global recode / banding"     = "recode",
            "Top / bottom coding"         = "topbottom",
            "Microaggregation"            = "microaggregate",
            "PRAM (post-randomisation)"   = "pram",
            "Noise addition (incl. DP-Laplace)" = "noise",
            "Synthetic replacement"       = "synth")),
        uiOutput("sdc_tx_params")),
      div(
        actionButton("btn_sdc_preview", "Preview effect", class = "btn-outline-primary"),
        actionButton("btn_sdc_apply", "Apply to treated table", class = "btn-primary ms-1"),
        actionButton("btn_sdc_reset", "Reset treatments", class = "btn-outline-secondary ms-1"),
        downloadButton("dl_sdc", "Download treated table", class = "btn-outline-success ms-1")),
      verbatimTextOutput("sdc_tx_out"),
      uiOutput("sdc_treated_note"))
  ),

  # 8. AUDIT
  nav_panel("8 · Audit", icon = icon("clipboard-check"),
    card(card_header("Audit log (hash-chained)"),
      div(actionButton("btn_verify", "Verify chain integrity"),
          span(textOutput("audit_status", inline = TRUE), class="ms-3")),
      DTOutput("audit_table")),
    card(card_header("File manifest (SHA-256)"), DTOutput("manifest_table"))
  ),

  # 9. SIGN-OFF & HANDOFF
  nav_panel("9 · Sign-off", icon = icon("signature"),
    layout_columns(col_widths = c(6,6),
      card(card_header("Sign the current stage"),
        p("Each person signs their stage with a per-user key. The public key ",
          "travels in the bundle so the other machine can verify it."),
        actionButton("btn_sign", "Sign as current role", class="btn-primary"),
        verbatimTextOutput("sign_out")),
      card(card_header("Handoff bundle"),
        p("Export a signed project bundle for the reviewer on another machine; ",
          "import theirs to continue."),
        downloadButton("dl_bundle", "Export signed bundle (.zip)"),
        fileInput("imp_bundle", "Import a bundle (.zip)", accept = ".zip"),
        actionButton("btn_cert", "Generate de-identification certificate"),
        div(class = "mt-2", downloadButton("dl_cert_pdf",
              "Download human-readable certificate + report (PDF)")),
        p(class = "small text-muted mt-1",
          "The PDF is rendered offline in pure R (no network, no external ",
          "tools) and paginates the certificate, column policy, file manifest, ",
          "signatures, and the full tamper-evident audit trail."),
        verbatimTextOutput("cert_out")))
  ),

  # DOCUMENTS · PDF / XML / vendor ECG
  nav_panel("Documents", icon = icon("file-shield"),
    layout_columns(col_widths = c(5, 7),
      card(card_header("Redact a document (PDF / XML / ECG)"),
        p(class = "small text-muted",
          "Digital & scanned PDFs (true redaction — the text layer is removed, ",
          "not just covered) and XML: generic, HL7 CDA / FHIR, and vendor ECG ",
          "(Philips SierraECG / iECG, GE MUSE). ECG waveform payloads are preserved."),
        fileInput("doc_file", NULL, accept = c(".pdf", ".xml"), width = "100%"),
        uiOutput("doc_type"),
        conditionalPanel("output.doc_is_pdf == true",
          sliderInput("doc_dpi", "Render DPI (higher = finer / slower)", 100, 300, 150, 25),
          checkboxInput("doc_force_ocr", "Force OCR (scanned pages / image-only)", FALSE)),
        conditionalPanel("output.doc_is_xml == true",
          checkboxInput("doc_sweep", "Also sweep free-text for stray PII", TRUE)),
        checkboxInput("doc_postal6",
          "Treat bare 6-digit numbers as postal codes (XML: mask last 3; PDF: redact)",
          FALSE),
        div(class = "mt-2",
          actionButton("btn_doc_detect", "Detect PII"),
          actionButton("btn_doc_redact", "Redact / scrub", class = "btn-primary")),
        uiOutput("doc_status"),
        div(class = "mt-2", downloadButton("dl_doc", "Download redacted file"))),
      card(card_header("Findings / changes"), DTOutput("doc_findings")))
  ),

  # BATCH · run the same pipelines over many files
  nav_panel("Batch", icon = icon("layer-group"),
    h4("Batch de-identification"),
    p(class="small text-muted", "Runs the same pipelines as the single-file tabs ",
      "over many inputs into this project's outputs, manifest, and audit trail. ",
      "Tables use the current column policy; PDF/XML use the Documents pipeline."),
    textInput("batch_dir", "Input folder (or ;-separated paths)"),
    checkboxInput("batch_recursive", "Recurse into subfolders", FALSE),
    numericInput("batch_workers", "Parallel workers", 1, min = 1, max = 8),
    checkboxInput("batch_force", "Redo files that already have output", FALSE),
    actionButton("btn_batch", "Run batch", class = "btn-primary"),
    br(), br(),
    DTOutput("batch_tbl"),
    downloadButton("dl_batch_summary", "Download batch summary (CSV)"))
)

# ---- server -----------------------------------------------------------------

server <- function(input, output, session) {
  rv <- reactiveValues(proj = NULL, df = NULL, path = NULL, deid = NULL,
                       findings = NULL, ft_rejects = character(0),
                       profile = NULL, suggestion = NULL,
                       userkey = NULL, doc = NULL, cert = NULL,
                       sdc_treated = NULL, sdc_steps = NULL, batch = NULL)

  # Re-render after an explicit probe so the operator sees the new status.
  output$py_status <- renderText({ input$btn_enable_ner; se_py_status_text() })

  # Explicit "Enable NER" — actively probes the BUNDLED interpreter only.
  # Never auto-provisions (se_py_probe no-ops unless a real interpreter exists).
  observeEvent(input$btn_enable_ner, {
    st <- se_py_probe()
    ready <- isTRUE(st$presidio) && isTRUE(st$spacy)
    showNotification(
      if (ready) "Offline NER ready (Presidio + spaCy)."
      else "No bundled NER engine found — staying in rules-only mode. See docs/ner_packaging.md.",
      type = if (ready) "message" else "warning")
  })

  # ---- project ----
  output$proj_status <- renderUI({
    if (is.null(rv$proj)) return(div(class="text-muted", "No project open."))
    p <- rv$proj
    tagList(
      div(tags$b("Project: "), p$name),
      div(tags$b("Stage: "), p$stage),
      div(tags$b("Scope: "), p$hash_scope),
      div(class="small text-muted", p$dir))
  })

  observeEvent(input$btn_create, {
    req(nzchar(input$proj_dir))
    tryCatch({
      rv$proj <- se_project_create(input$proj_dir, input$proj_name,
                                   actor = input$actor, hash_scope = input$hash_scope)
      showNotification("Project created.", type = "message")
    }, error = function(e) showNotification(paste("Create failed:", conditionMessage(e)),
                                            type = "error"))
  })
  observeEvent(input$btn_open, {
    req(nzchar(input$proj_dir))
    tryCatch({
      rv$proj <- se_project_open(input$proj_dir)
      showNotification("Project opened.", type = "message")
    }, error = function(e) showNotification(paste("Open failed:", conditionMessage(e)),
                                            type = "error"))
  })

  # ---- import ----
  output$sheet_ui <- renderUI({
    req(input$file)
    if (tolower(tools::file_ext(input$file$name)) %in% c("xlsx","xls")) {
      sheets <- tryCatch(readxl::excel_sheets(input$file$datapath), error=function(e) NULL)
      if (!is.null(sheets)) selectInput("sheet", "Sheet", sheets)
    }
  })

  observeEvent(input$file, {
    req(input$file)
    df <- tryCatch(se_read_table(input$file$datapath, input$sheet),
                   error = function(e) { showNotification(conditionMessage(e), type="error"); NULL })
    req(df)
    rv$df <- df
    rv$deid <- NULL
    if (!is.null(rv$proj)) {
      # register a copy under inputs/ using the original filename
      dest <- file.path(se_project_paths(rv$proj$dir)$inputs, input$file$name)
      file.copy(input$file$datapath, dest, overwrite = TRUE)
      rv$proj <- se_register_input(rv$proj, dest, actor = input$actor)
      rv$path <- dest
    }
  })

  output$import_info <- renderText({
    req(rv$df)
    sha <- if (!is.null(rv$path)) substr(se_sha256_file(rv$path), 1, 16) else "(not registered)"
    sprintf("%d rows x %d columns.  SHA-256: %s...", nrow(rv$df), ncol(rv$df), sha)
  })
  output$preview <- renderDT({
    req(rv$df); datatable(head(rv$df, 200), options = list(scrollX = TRUE, pageLength = 10))
  })

  # ---- detect ----
  observeEvent(input$btn_detect, {
    req(rv$df)
    withProgress(message = "Scanning...", {
      rv$suggestion <- se_suggest_mapping(rv$df)
      rv$profile <- rv$suggestion$profile
      # free-text findings on likely note columns: rules always, NER/LLM opt-in
      ff <- se_detect_freetext(rv$df,
              use_pf = isTRUE(input$use_pf),
              use_ner = isTRUE(input$use_ner), use_llm = isTRUE(input$use_llm))
      rv$findings <- if (nrow(ff)) ff else NULL
    })
    if (!is.null(rv$proj))
      se_audit_append(se_project_paths(rv$proj$dir)$audit, "detect", input$actor,
                      list(outliers = nrow(rv$profile$outliers),
                           freetext = if (is.null(rv$findings)) 0L else nrow(rv$findings),
                           pf = isTRUE(input$use_pf),
                           ner = isTRUE(input$use_ner), llm = isTRUE(input$use_llm)))
  })

  output$outliers <- renderDT({
    req(rv$profile)
    datatable(rv$profile$outliers, options = list(scrollX = TRUE, pageLength = 10),
              rownames = FALSE) |>
      formatStyle("severity", target = "row",
                  backgroundColor = styleEqual(c("high","medium"),
                                               c("#f8d7da", "#fff3cd")))
  })
  output$freetext_findings <- renderDT({
    if (is.null(rv$findings)) return(datatable(data.frame(message = "Run detection.")))
    datatable(rv$findings, selection = "multiple",
              options = list(scrollX = TRUE, pageLength = 10), rownames = FALSE)
  })

  observeEvent(input$freetext_findings_rows_selected, ignoreNULL = FALSE, {
    sel <- input$freetext_findings_rows_selected
    if (is.null(rv$findings) || is.null(sel) || !length(sel)) { rv$ft_rejects <- character(0); return() }
    f <- rv$findings[sel, , drop = FALSE]
    rv$ft_rejects <- paste(f$column, f$type, tolower(f$match), sep = "\t")
  })

  # ---- policy ----
  observeEvent(rv$df, {
    updateSelectInput(session, "shift_subject_col",
      choices = c("(dataset-wide)" = "", stats::setNames(names(rv$df), names(rv$df))))
  })

  observeEvent(input$btn_autosuggest, {
    req(rv$df)
    if (is.null(rv$suggestion)) rv$suggestion <- se_suggest_mapping(rv$df)
    showNotification("Mapping suggested from names + content.", type = "message")
  })

  output$policy_ui <- renderUI({
    req(rv$df)
    idents <- se_default_identifiers()
    ident_choices <- c("(none / keep)" = "keep",
                       setNames(vapply(idents, `[[`, "", "id"),
                                vapply(idents, `[[`, "", "label")))
    sugg <- rv$suggestion$mapping %||% list()
    rows <- lapply(names(rv$df), function(cn) {
      sel_ident <- sugg[[cn]] %||% "keep"; if (is.na(sel_ident)) sel_ident <- "keep"
      def_act <- if (sel_ident == "keep") "keep" else
        (se_identifier(sel_ident)$default_action %||% "pseudonymize")
      layout_columns(col_widths = c(4,4,4),
        div(tags$b(cn), tags$br(),
            span(class="small text-muted",
                 paste0("shape: ", rv$profile$per_column[[cn]]$dominant_shape %||% "?"))),
        selectInput(paste0("ident_", cn), NULL, ident_choices, selected = sel_ident),
        selectInput(paste0("act_", cn), NULL, se_action_choices(), selected = def_act))
    })
    tagList(rows)
  })

  build_policy <- function() {
    cols <- list()
    ftcols <- character(0)
    for (cn in names(rv$df)) {
      ident <- input[[paste0("ident_", cn)]] %||% "keep"
      act <- input[[paste0("act_", cn)]] %||% "keep"
      if (act == "redact_freetext") ftcols <- c(ftcols, cn)
      opts <- list(fpe_mode = se_identifier(ident)$fpe_mode,
                   generalize = if (act == "generalize") input$date_method
                                else se_identifier(ident)$generalize)
      if (identical(input$date_method, "date_shift")) {
        opts$shift_window <- as.integer(input$shift_window %||% 365L)
        opts$shift_subject_col <- input$shift_subject_col %||% ""
      }
      cols[[cn]] <- list(identifier = if (ident=="keep") NA else ident,
                         action = act, options = opts)
    }
    types_sel <- input$ft_types %||% NULL
    freetext_opts <- list(use_pf = isTRUE(input$use_pf),
                          min_conf = as.numeric(input$ft_min_conf %||% 0.5),
                          types = types_sel,
                          rejects = rv$ft_rejects %||% character(0))
    list(columns = cols, freetext_columns = ftcols, freetext_opts = freetext_opts)
  }

  observeEvent(input$btn_save_policy, {
    req(rv$df, rv$proj)
    rv$proj$policy <- build_policy()
    rv$proj <- se_project_save(rv$proj)
    se_audit_append(se_project_paths(rv$proj$dir)$audit, "policy_save", input$actor,
                    list(columns = length(rv$proj$policy$columns)))
    showNotification("Policy saved to project.json.", type = "message")
  })

  # ---- de-identify ----
  observeEvent(input$btn_deid, {
    req(rv$df, rv$proj)
    if (input$role != "deidentifier") {
      showNotification("Only the De-identifier role can run de-identification.",
                       type = "error"); return()
    }
    policy <- if (length(rv$proj$policy$columns)) rv$proj$policy else build_policy()
    p <- se_project_paths(rv$proj$dir)
    key <- se_resolve_key(rv$proj$hash_scope, rv$proj)

    # The engine reads from disk so it can chunk/resume. Use the loaded file if
    # it is a real path; otherwise snapshot the in-memory table under work/.
    src <- rv$path
    if (is.null(src) || !file.exists(src)) {
      src <- file.path(p$work, "table.csv")
      data.table::fwrite(rv$df, src)
    }
    par_arg <- if (isTRUE(input$parallel)) max(1L, as.integer(input$workers %||% 2L)) else FALSE

    withProgress(message = "De-identifying...", value = 0, {
      res <- se_deidentify_file(
        rv$proj, src, policy, key, out_format = input$out_format,
        chunk_size = as.integer(input$chunk_size %||% 50000L),
        parallel = par_arg,
        app_r_dir = getOption("se.app_r_dir"),
        progress_cb = function(done, total)
          setProgress(value = if (total > 0) done / total else 1,
                      detail = sprintf("chunk %d / %d", done, total)))
      # Make Review + SDC memory-safe: only hold the whole output in memory when
      # it is small; otherwise page (Review) / sample (SDC) it from disk via
      # readers, so a huge finished output is never loaded in full.
      inmem_max  <- getOption("se.deid_inmem_max", 200000L)
      big        <- isTRUE(res$nrec > inmem_max)
      out_reader <- se_open_table(res$output, format = input$out_format)
      src_reader <- tryCatch(se_open_table(src), error = function(e) NULL)
      deid_data  <- if (big) NULL else se_read_window(out_reader, 1L, res$nrec)
      rv$deid <- list(output = res$output, format = input$out_format,
                      reader = out_reader, src_reader = src_reader,
                      data = deid_data, big = big, nrec = res$nrec,
                      crosswalk = res$crosswalk, summary = res$summary,
                      resumed = res$resumed, n_chunks = res$n_chunks,
                      mode = res$mode)

      blob <- se_crosswalk_encrypt(res$crosswalk, key)
      saveRDS(blob, p$crosswalk)
      se_manifest_write(rv$proj)
      rv$proj$stage <- "deidentified"; rv$proj <- se_project_save(rv$proj)
      se_audit_append(p$audit, "deidentify", input$actor,
                      list(output = basename(res$output),
                           chunks = res$n_chunks, resumed = res$resumed,
                           mode = res$mode, parallel = !isFALSE(par_arg),
                           crosswalk_rows = nrow(res$crosswalk),
                           out_sha256 = substr(res$out_sha %||% se_sha256_file(res$output), 1, 16)))
    })
    showNotification(sprintf("De-identification complete (%d chunks%s). See Review output.",
                             rv$deid$n_chunks, if (isTRUE(rv$deid$resumed)) ", resumed" else ""),
                     type = "message")
  })

  output$deid_resume <- renderText({
    req(rv$proj)
    src <- rv$path
    if (is.null(src) || !file.exists(src)) src <- file.path(se_project_paths(rv$proj$dir)$work, "table.csv")
    if (!file.exists(src)) return("")
    st <- se_deidentify_status(rv$proj, src, as.integer(input$chunk_size %||% 50000L))
    if (!isTRUE(st$exists)) return("No prior run for this file — a fresh run will start from chunk 1.")
    if (identical(st$stage, "complete"))
      sprintf("Previous run complete: %s (%d chunks). Re-running resumes/rebuilds from checkpoints.",
              st$output %||% "", st$done)
    else
      sprintf("Resumable: %d / %s chunks already done — a run will continue from there.",
              st$done, as.character(st$total))
  })

  output$deid_summary <- renderText({
    if (is.null(rv$deid)) return("No de-identification run yet.")
    s <- rv$deid$summary
    lines <- vapply(s, function(x) sprintf("  %-16s %-16s changed=%d",
                    x$column, x$action, x$n_changed), character(1))
    paste0("Columns processed: ", length(s), "\n",
           "Crosswalk rows (reversible): ", nrow(rv$deid$crosswalk), "\n\n",
           paste(lines, collapse = "\n"))
  })

  # ---- review output ----
  # Side-by-side review reads a bounded row window from disk (via checkpoint.R
  # readers), so even a huge finished output is browsed a window at a time
  # rather than loaded whole.
  output$review_controls <- renderUI({
    req(rv$deid)
    wmax <- getOption("se.review_window_max", 1000L)
    tagList(
      layout_columns(col_widths = c(4, 4, 4),
        selectInput("review_col", "Column", rv$deid$reader$header, width = "100%"),
        numericInput("review_start", "First row", value = 1, min = 1, step = wmax),
        numericInput("review_n", "Rows to show", value = min(200L, wmax),
                     min = 1, max = wmax, step = 50)),
      div(class = "small text-muted", textOutput("review_caption", inline = TRUE)))
  })
  output$review_caption <- renderText({
    req(rv$deid)
    n <- format(rv$deid$nrec, big.mark = ",")
    if (isTRUE(rv$deid$big))
      sprintf("Large output (%s rows) — browse by window; nothing is loaded in full.", n)
    else sprintf("%s rows.", n)
  })
  output$review_table <- renderDT({
    req(rv$deid, input$review_col)
    cn    <- input$review_col
    wmax  <- getOption("se.review_window_max", 1000L)
    start <- max(1L, as.integer(input$review_start %||% 1L))
    n     <- max(1L, min(as.integer(input$review_n %||% 200L), wmax))
    deid_w <- se_read_window(rv$deid$reader, start, n)
    src_w  <- if (!is.null(rv$deid$src_reader))
                se_read_window(rv$deid$src_reader, start, n) else NULL
    rows   <- seq.int(start, length.out = nrow(deid_w))
    oc <- rep(NA_character_, nrow(deid_w))
    if (!is.null(src_w) && cn %in% names(src_w) && nrow(src_w) == nrow(deid_w))
      oc <- as.character(src_w[[cn]])
    d <- data.frame(row = rows, original = oc,
                    de_identified = if (cn %in% names(deid_w))
                                      as.character(deid_w[[cn]]) else NA_character_,
                    stringsAsFactors = FALSE)
    datatable(d, options = list(pageLength = 15, scrollX = TRUE), rownames = FALSE)
  })
  observeEvent(input$btn_approve, {
    req(rv$proj)
    if (input$role != "reviewer") { showNotification("Reviewer role required.", type="error"); return() }
    rv$proj$stage <- "reviewed"; rv$proj <- se_project_save(rv$proj)
    se_audit_append(se_project_paths(rv$proj$dir)$audit, "review_approve", input$actor, list())
    showNotification("Approved.", type = "message")
  })
  observeEvent(input$btn_return, {
    req(rv$proj)
    se_audit_append(se_project_paths(rv$proj$dir)$audit, "review_return", input$actor, list())
    showNotification("Returned to de-identifier.", type = "warning")
  })

  # ---- SDC ----
  output$sdc_quasi_ui <- renderUI({
    req(rv$df)
    selectInput("sdc_quasi", "Quasi-identifier columns", names(rv$df),
                multiple = TRUE, width = "100%")
  })

  # Bounded, representative working sample of the current output (or input).
  # Both the measures and the transforms operate on this same sample so treated
  # rows stay aligned with the original for DCR.
  .sdc_sample <- reactive({
    cap <- getOption("se.sdc_sample_cap", 20000L)
    if (!is.null(rv$deid)) se_sample_table(rv$deid$reader, max_rows = cap)
    else { req(rv$df); se_sample_table(se_reader_from_df(rv$df), max_rows = cap) }
  })
  # The table transforms act on: the accumulated treated copy if any, else the
  # working sample.
  .sdc_work <- reactive({
    if (!is.null(rv$sdc_treated)) rv$sdc_treated else .sdc_sample()$data
  })

  observeEvent(input$btn_sdc, {
    req(input$sdc_quasi)
    steps <- input$sdc_steps
    samp  <- .sdc_sample()
    treated <- !is.null(rv$sdc_treated)
    d <- if (treated) rv$sdc_treated else samp$data
    ref <- if ("dcr" %in% steps && !is.null(rv$deid) && !is.null(rv$deid$src_reader))
             se_read_blocks(rv$deid$src_reader, samp$blocks) else NULL
    out <- c()
    if (treated)
      out <- c(out, sprintf("Measured on the TREATED table (%d transform step(s) applied).",
                            length(rv$sdc_steps)), "")
    if (isTRUE(samp$sampled))
      out <- c(out, sprintf("NOTE: estimated from a random sample of %s of %s rows.",
                            format(samp$n, big.mark = ","),
                            format(samp$nrec, big.mark = ",")), "")
    if ("kanon" %in% steps) {
      ka <- se_kanon(d, input$sdc_quasi, input$sdc_k)
      out <- c(out, sprintf("k-anonymity: k_achieved=%d, %d records below k=%d (%.1f%%), uniques=%d",
                            ka$k_achieved, ka$n_below_k, input$sdc_k, 100*ka$frac_below_k, ka$n_unique))
    }
    if ("ldiv" %in% steps) {
      sc <- setdiff(names(d), input$sdc_quasi)[1]
      ld <- se_ldiversity(d, input$sdc_quasi, sc)
      if (!is.null(ld)) out <- c(out, sprintf("l-diversity on '%s': l_min=%d", ld$sensitive, ld$l_min))
    }
    if ("suda" %in% steps) {
      su <- se_sample_uniques(d, input$sdc_quasi)
      out <- c(out, sprintf("sample uniques: full=%.1f%%, worst subset=%.1f%%",
                            100*su$frac_unique_full, 100*(su$max_subset_unique %||% NA)))
    }
    if ("risk" %in% steps) {
      ir <- se_individual_risk(d, input$sdc_quasi)
      if (!is.null(ir)) out <- c(out, sprintf("individual risk: mean=%.4f max=%.4f expected re-id=%.1f",
                                              ir$risk_mean, ir$risk_max, ir$expected_reident))
      else out <- c(out, "individual risk: sdcMicro unavailable/failed.")
    }
    if ("dcr" %in% steps && !is.null(ref) && nrow(ref) == nrow(d)) {
      dc <- se_dcr(d, ref, input$sdc_quasi)
      if (!is.null(dc)) out <- c(out, sprintf("DCR vs original: min=%.3f mean=%.3f exact-matches=%.1f%%",
                                              dc$dcr_min, dc$dcr_mean, 100*dc$frac_zero))
    }
    gate <- se_sdc_gate(d, input$sdc_quasi, list(k = input$sdc_k, max_risk = 0.05))
    out <- c(out, "",
             if (gate$pass) "EXPORT GATE: PASS" else
               paste0("EXPORT GATE: BLOCKED\n  - ", paste(gate$reasons, collapse = "\n  - ")),
             if (isTRUE(samp$sampled))
               "  (gate evaluated on a sample — an estimate, not a whole-file guarantee)")
    output$sdc_out <- renderText(paste(out, collapse = "\n"))
    if (!is.null(rv$proj))
      se_audit_append(se_project_paths(rv$proj$dir)$audit, "sdc_run", input$actor,
                      list(steps = steps, gate_pass = gate$pass, treated = treated,
                           n_transforms = length(rv$sdc_steps),
                           sampled = isTRUE(samp$sampled), sample_n = samp$n,
                           nrec = samp$nrec))
  })

  # ---- SDC risk-reduction transforms ----
  # Column choices come from the working table (treated copy or sample).
  .sdc_cols <- reactive({ names(.sdc_work()) })

  output$sdc_tx_params <- renderUI({
    cols <- tryCatch(.sdc_cols(), error = function(e) character(0))
    quasi <- input$sdc_quasi
    numdefault <- if (length(quasi)) quasi else cols
    switch(input$sdc_tx %||% "suppress",
      suppress = tagList(
        div(class = "small text-muted",
            "Blanks the quasi-identifier cells of every record in a group smaller than ",
            "Target k (set above). Optionally restrict to specific columns."),
        selectInput("sdc_sup_cols", "Columns to blank (default: all quasi)",
                    choices = cols, selected = quasi, multiple = TRUE, width = "100%")),
      recode = tagList(
        selectInput("sdc_rc_col", "Column", choices = cols, width = "60%"),
        radioButtons("sdc_rc_mode", NULL,
                     c("Numeric bands" = "bands", "Categorical mapping" = "map"), inline = TRUE),
        conditionalPanel("input.sdc_rc_mode == 'bands'",
          textInput("sdc_rc_breaks", "Break points (comma-separated)", "0,30,50,70,120"),
          textInput("sdc_rc_labels", "Labels (optional, comma-separated)", "<30,30-49,50-69,70+")),
        conditionalPanel("input.sdc_rc_mode == 'map'",
          textInput("sdc_rc_map", "Mapping  old=new, old2=new2", "Malay=Minority, Indian=Minority"))),
      topbottom = tagList(
        selectInput("sdc_tb_col", "Numeric column", choices = cols, width = "60%"),
        layout_columns(col_widths = c(6, 6),
          numericInput("sdc_tb_top", "Cap top percentile (0 = off)", value = 0.01, min = 0, max = 0.5, step = 0.01),
          numericInput("sdc_tb_bot", "Cap bottom percentile (0 = off)", value = 0.01, min = 0, max = 0.5, step = 0.01))),
      microaggregate = tagList(
        selectInput("sdc_ma_cols", "Numeric columns", choices = cols, selected = NULL, multiple = TRUE, width = "100%"),
        layout_columns(col_widths = c(6, 6),
          numericInput("sdc_ma_aggr", "Group size (>= k)", value = 5, min = 2, step = 1),
          radioButtons("sdc_ma_method", "Replace with", c("mean", "median"), inline = TRUE))),
      pram = tagList(
        selectInput("sdc_pr_col", "Categorical column", choices = cols, width = "60%"),
        layout_columns(col_widths = c(6, 6),
          numericInput("sdc_pr_retain", "Retention probability", value = 0.8, min = 0, max = 1, step = 0.05),
          numericInput("sdc_pr_seed", "Seed", value = 1, min = 1, step = 1))),
      noise = tagList(
        selectInput("sdc_no_cols", "Numeric columns", choices = cols, selected = NULL, multiple = TRUE, width = "100%"),
        radioButtons("sdc_no_method", "Mechanism",
                     c("Gaussian (% of SD)" = "gaussian", "Laplace / DP-style" = "laplace"), inline = TRUE),
        conditionalPanel("input.sdc_no_method == 'gaussian'",
          numericInput("sdc_no_pct", "Noise as fraction of SD", value = 0.1, min = 0, step = 0.05)),
        conditionalPanel("input.sdc_no_method == 'laplace'",
          layout_columns(col_widths = c(4, 4, 4),
            numericInput("sdc_no_eps", "epsilon (0 = use %SD)", value = 1, min = 0, step = 0.1),
            numericInput("sdc_no_lo", "clamp lower (blank = data min)", value = NA),
            numericInput("sdc_no_hi", "clamp upper (blank = data max)", value = NA))),
        numericInput("sdc_no_seed", "Seed", value = 1, min = 1, step = 1, width = "150px")),
      synth = tagList(
        selectInput("sdc_sy_cols", "Columns to synthesise (default: quasi)",
                    choices = cols, selected = quasi, multiple = TRUE, width = "100%"),
        radioButtons("sdc_sy_mode", "Method",
          c("Independent marginal (pure R)" = "marginal",
            "Joint (flexsynth, if installed)" = "flexsynth"), inline = TRUE),
        div(class = "small text-muted",
            if (se_sdc_synth_available()) "flexsynth detected: joint synthesis available."
            else "flexsynth not installed: 'Joint' falls back to marginal resynthesis."),
        numericInput("sdc_sy_seed", "Seed", value = 1, min = 1, step = 1, width = "150px")))
  })

  # Build a transform spec (list(op, args)) from the current inputs, or a
  # character error string if the inputs are incomplete.
  .sdc_build_step <- function() {
    op <- input$sdc_tx %||% "suppress"
    parse_nums <- function(s) {
      v <- suppressWarnings(as.numeric(trimws(strsplit(s %||% "", ",")[[1]])))
      v[!is.na(v)]
    }
    if (op == "suppress") {
      req(input$sdc_quasi)
      cols <- input$sdc_sup_cols; if (!length(cols)) cols <- NULL
      list(op = "suppress", args = list(quasi_cols = input$sdc_quasi,
                                        k = as.integer(input$sdc_k %||% 5L), cols = cols))
    } else if (op == "recode") {
      if (is.null(input$sdc_rc_col)) return("Choose a column.")
      if ((input$sdc_rc_mode %||% "bands") == "bands") {
        br <- parse_nums(input$sdc_rc_breaks)
        if (length(br) < 2) return("Give at least two break points.")
        lb <- trimws(strsplit(input$sdc_rc_labels %||% "", ",")[[1]]); lb <- lb[nzchar(lb)]
        if (length(lb) != length(br) - 1L) lb <- NULL
        list(op = "recode", args = list(col = input$sdc_rc_col, breaks = br, labels = lb))
      } else {
        pairs <- strsplit(trimws(strsplit(input$sdc_rc_map %||% "", ",")[[1]]), "=")
        pairs <- pairs[vapply(pairs, length, 1L) == 2L]
        if (!length(pairs)) return("Give mappings as old=new, comma-separated.")
        mp <- setNames(trimws(vapply(pairs, `[`, "", 2L)), trimws(vapply(pairs, `[`, "", 1L)))
        list(op = "recode", args = list(col = input$sdc_rc_col, mapping = mp))
      }
    } else if (op == "topbottom") {
      if (is.null(input$sdc_tb_col)) return("Choose a column.")
      tp <- if ((input$sdc_tb_top %||% 0) > 0) input$sdc_tb_top else NULL
      bt <- if ((input$sdc_tb_bot %||% 0) > 0) input$sdc_tb_bot else NULL
      if (is.null(tp) && is.null(bt)) return("Set a top and/or bottom percentile > 0.")
      list(op = "topbottom", args = list(col = input$sdc_tb_col, top_pct = tp, bottom_pct = bt))
    } else if (op == "microaggregate") {
      if (!length(input$sdc_ma_cols)) return("Choose one or more numeric columns.")
      list(op = "microaggregate", args = list(cols = input$sdc_ma_cols,
           aggr = as.integer(input$sdc_ma_aggr %||% 5L), method = input$sdc_ma_method %||% "mean"))
    } else if (op == "pram") {
      if (is.null(input$sdc_pr_col)) return("Choose a column.")
      list(op = "pram", args = list(col = input$sdc_pr_col,
           retain = input$sdc_pr_retain %||% 0.8, seed = as.integer(input$sdc_pr_seed %||% 1L)))
    } else if (op == "noise") {
      if (!length(input$sdc_no_cols)) return("Choose one or more numeric columns.")
      if ((input$sdc_no_method %||% "gaussian") == "gaussian") {
        list(op = "noise", args = list(cols = input$sdc_no_cols, method = "gaussian",
             pct = input$sdc_no_pct %||% 0.1, seed = as.integer(input$sdc_no_seed %||% 1L)))
      } else {
        eps <- input$sdc_no_eps %||% 0
        lo <- if (is.na(input$sdc_no_lo)) NULL else input$sdc_no_lo
        hi <- if (is.na(input$sdc_no_hi)) NULL else input$sdc_no_hi
        list(op = "noise", args = list(cols = input$sdc_no_cols, method = "laplace",
             epsilon = if (eps > 0) eps else NULL, lower = lo, upper = hi,
             pct = 0.1, seed = as.integer(input$sdc_no_seed %||% 1L)))
      }
    } else if (op == "synth") {
      cols <- input$sdc_sy_cols; if (!length(cols)) return("Choose columns to synthesise.")
      if ((input$sdc_sy_mode %||% "marginal") == "flexsynth")
        list(op = "synth_flexsynth", args = list(cols = cols, seed = as.integer(input$sdc_sy_seed %||% 1L)))
      else
        list(op = "synth", args = list(cols = cols, seed = as.integer(input$sdc_sy_seed %||% 1L)))
    } else "Unknown transform."
  }

  # Run one step against a base table (handles the flexsynth op which is not in
  # the se_sdc_apply dispatcher).
  .sdc_run_step <- function(base, step) {
    if (step$op == "synth_flexsynth")
      do.call(se_sdc_synth_flexsynth, c(list(base), step$args))
    else se_sdc_apply(base, list(step))  # returns list(data, log) for known ops
  }

  observeEvent(input$btn_sdc_preview, {
    step <- .sdc_build_step()
    if (is.character(step)) { output$sdc_tx_out <- renderText(step); return() }
    base <- .sdc_work()
    res <- .sdc_run_step(base, step)
    treated <- if (!is.null(res$data)) res$data else base
    note <- if (!is.null(res$note)) res$note else paste(res$log, collapse = "\n")
    q <- input$sdc_quasi
    lines <- c(paste0("PREVIEW — ", note))
    if (length(q)) {
      k0 <- se_kanon(base, q, input$sdc_k); k1 <- se_kanon(treated, q, input$sdc_k)
      if (!is.null(k0) && !is.null(k1))
        lines <- c(lines, "",
          sprintf("k-anon  before: k=%d, below-k=%d, uniques=%d", k0$k_achieved, k0$n_below_k, k0$n_unique),
          sprintf("k-anon  after : k=%d, below-k=%d, uniques=%d", k1$k_achieved, k1$n_below_k, k1$n_unique))
    } else lines <- c(lines, "", "(select quasi-identifier columns above to see the k-anon effect)")
    lines <- c(lines, "", "Not committed — click \"Apply to treated table\" to keep it.")
    output$sdc_tx_out <- renderText(paste(lines, collapse = "\n"))
  })

  observeEvent(input$btn_sdc_apply, {
    step <- .sdc_build_step()
    if (is.character(step)) { output$sdc_tx_out <- renderText(step); return() }
    base <- .sdc_work()
    res <- .sdc_run_step(base, step)
    treated <- if (!is.null(res$data)) res$data else base
    note <- if (!is.null(res$note)) res$note else paste(res$log, collapse = "\n")
    rv$sdc_treated <- treated
    rv$sdc_steps <- c(rv$sdc_steps, list(list(step = step, note = note)))
    if (!is.null(rv$proj))
      se_audit_append(se_project_paths(rv$proj$dir)$audit, "sdc_transform", input$actor,
                      list(op = step$op, note = note, step_index = length(rv$sdc_steps)))
    log <- vapply(seq_along(rv$sdc_steps),
                  function(i) sprintf("%d. %s", i, rv$sdc_steps[[i]]$note), character(1))
    output$sdc_tx_out <- renderText(paste(c("Applied. Treatment so far:", "", log), collapse = "\n"))
    showNotification("Transform applied to the treated table.", type = "message")
  })

  observeEvent(input$btn_sdc_reset, {
    rv$sdc_treated <- NULL; rv$sdc_steps <- NULL
    output$sdc_tx_out <- renderText("Treatments cleared — back to the untreated working table.")
  })

  output$sdc_treated_note <- renderUI({
    if (is.null(rv$sdc_treated)) return(NULL)
    samp <- tryCatch(.sdc_sample(), error = function(e) list(sampled = FALSE))
    div(class = "small text-muted mt-2",
        sprintf("Treated table holds %s row(s) with %d transform step(s). ",
                format(nrow(rv$sdc_treated), big.mark = ","), length(rv$sdc_steps)),
        if (isTRUE(samp$sampled))
          "This is a bounded sample — analysis-only; download reflects the sample."
        else "Download or re-run the measures above to confirm it clears the gate.")
  })

  output$dl_sdc <- downloadHandler(
    filename = function() {
      base <- if (!is.null(rv$proj)) rv$proj$name else "table"
      sprintf("%s_sdc_treated.csv", base)
    },
    content = function(file) {
      d <- rv$sdc_treated
      if (is.null(d)) d <- .sdc_work()
      utils::write.csv(d, file, row.names = FALSE, na = "")
      if (!is.null(rv$proj))
        se_audit_append(se_project_paths(rv$proj$dir)$audit, "sdc_export_treated", input$actor,
                        list(rows = nrow(d), transforms = length(rv$sdc_steps)))
    }
  )

  # ---- audit ----
  output$audit_table <- renderDT({
    req(rv$proj)
    input$btn_verify; input$btn_deid; input$btn_detect  # refresh triggers
    a <- se_audit_read(se_project_paths(rv$proj$dir)$audit)
    datatable(a, options = list(pageLength = 15, scrollX = TRUE), rownames = FALSE)
  })
  observeEvent(input$btn_verify, {
    req(rv$proj)
    v <- se_audit_verify(se_project_paths(rv$proj$dir)$audit)
    output$audit_status <- renderText(
      if (v$ok) sprintf("Chain OK (%d entries).", v$n)
      else sprintf("TAMPER DETECTED at entry %d.", v$broken_at))
  })
  output$manifest_table <- renderDT({
    req(rv$proj)
    mp <- se_project_paths(rv$proj$dir)$manifest
    if (!file.exists(mp)) return(datatable(data.frame(message="No manifest yet.")))
    m <- jsonlite::fromJSON(mp)$entries
    datatable(m, options = list(scrollX = TRUE), rownames = FALSE)
  })

  # ---- sign-off & handoff ----
  observeEvent(input$btn_sign, {
    req(rv$proj)
    if (is.null(rv$userkey)) rv$userkey <- se_sig_keygen()
    p <- se_project_paths(rv$proj$dir)
    payload <- list(stage = rv$proj$stage, actor = input$actor, role = input$role,
                    manifest_sha = if (file.exists(p$manifest)) se_sha256_file(p$manifest) else NA,
                    when = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
    sig <- se_sign(payload, rv$userkey$secret)
    dir.create(p$signatures, showWarnings = FALSE, recursive = TRUE)
    saveRDS(list(payload = payload, signature = sig, public = rv$userkey$public),
            file.path(p$signatures, paste0(input$role, ".sig.rds")))
    se_audit_append(p$audit, "signoff", input$actor, list(role = input$role, stage = rv$proj$stage))
    output$sign_out <- renderText(paste0("Signed stage '", rv$proj$stage,
                                         "' as ", input$actor, " (", input$role, ")."))
  })

  output$dl_bundle <- downloadHandler(
    filename = function() paste0(rv$proj$name %||% "project", "_bundle.zip"),
    content = function(file) {
      req(rv$proj)
      files <- list.files(rv$proj$dir, recursive = TRUE, full.names = TRUE)
      zip::zip(file, files = basename(rv$proj$dir),
               root = dirname(rv$proj$dir))
    })

  observeEvent(input$imp_bundle, {
    req(input$imp_bundle, rv$proj)
    tryCatch({
      zip::unzip(input$imp_bundle$datapath, exdir = dirname(rv$proj$dir))
      showNotification("Bundle imported. Re-open the project to continue.", type="message")
    }, error = function(e) showNotification(conditionMessage(e), type="error"))
  })

  observeEvent(input$btn_cert, {
    req(rv$proj)
    p <- se_project_paths(rv$proj$dir)
    cert <- se_cert_data(rv$proj, p)
    rv$cert <- cert
    # JSON certificate: a superset of the legacy fields, still auto-unboxed.
    jsonlite::write_json(cert, p$certificate, auto_unbox = TRUE, pretty = TRUE,
                         null = "null")
    output$cert_out <- renderText(paste(readLines(p$certificate), collapse = "\n"))
    se_audit_append(p$audit, "certificate", input$actor, list())
  })

  output$dl_cert_pdf <- downloadHandler(
    filename = function()
      paste0(rv$proj$name %||% "project", "_certificate.pdf"),
    content = function(file) {
      req(rv$proj)
      p <- se_project_paths(rv$proj$dir)
      cert <- rv$cert %||% se_cert_data(rv$proj, p)   # fresh if not yet generated
      se_report_pdf(cert, file)
      se_audit_append(p$audit, "certificate_pdf", input$actor, list())
    })

  # ---- documents (PDF / XML / vendor ECG) ----
  observeEvent(input$doc_file, {
    req(input$doc_file)
    rv$doc <- list(path = input$doc_file$datapath, name = input$doc_file$name,
                   ext = tolower(tools::file_ext(input$doc_file$name)),
                   findings = NULL, output = NULL, waveform_ok = NA, profile = NA)
  })

  output$doc_is_pdf <- reactive({ !is.null(rv$doc) && identical(rv$doc$ext, "pdf") })
  output$doc_is_xml <- reactive({ !is.null(rv$doc) && identical(rv$doc$ext, "xml") })
  outputOptions(output, "doc_is_pdf", suspendWhenHidden = FALSE)
  outputOptions(output, "doc_is_xml", suspendWhenHidden = FALSE)

  output$doc_type <- renderUI({
    d <- rv$doc
    if (is.null(d)) return(div(class = "text-muted", "No document loaded."))
    if (identical(d$ext, "xml")) {
      prof <- tryCatch(se_xml_profile(xml2::read_xml(d$path)), error = function(e) "unreadable")
      div(tags$b("XML profile: "), span(class = "badge bg-info", prof))
    } else if (identical(d$ext, "pdf")) {
      info <- tryCatch(pdftools::pdf_info(d$path), error = function(e) NULL)
      pd <- tryCatch(pdftools::pdf_data(d$path), error = function(e) NULL)
      has_text <- !is.null(pd) && any(vapply(pd, function(x) !is.null(x) && nrow(x) > 0, logical(1)))
      div(tags$b("PDF: "),
          sprintf("%s page(s) · %s", info$pages %||% "?",
                  if (has_text) "digital text layer" else "no text layer (will OCR)"))
    } else div(class = "text-danger", "Unsupported file type (PDF or XML only).")
  })

  # ephemeral key for detect-only previews and for ad-hoc redaction with no project
  .doc_key <- function() {
    if (!is.null(rv$proj)) se_resolve_key(rv$proj$hash_scope, rv$proj)
    else as.raw(sample(0:255, 32L, replace = TRUE))
  }

  observeEvent(input$btn_doc_detect, {
    req(rv$doc)
    d <- rv$doc
    old <- options(se.detect_postal6 = isTRUE(input$doc_postal6)); on.exit(options(old))
    withProgress(message = "Detecting...", {
      if (identical(d$ext, "xml")) {
        res <- tryCatch(se_xml_scrub(d$path, key = .doc_key(),
                                     sweep = isTRUE(input$doc_sweep)),
                        error = function(e) { showNotification(conditionMessage(e), type = "error"); NULL })
        req(res)
        rv$doc$findings <- res$changes[, c("xpath", "identifier", "action", "before"), drop = FALSE]
        rv$doc$profile <- res$profile
      } else if (identical(d$ext, "pdf")) {
        f <- tryCatch(se_pdf_detect(d$path, dpi = as.integer(input$doc_dpi %||% 150L),
                                    force_ocr = isTRUE(input$doc_force_ocr)),
                      error = function(e) { showNotification(conditionMessage(e), type = "error"); NULL })
        req(f)
        rv$doc$findings <- f[, c("page", "text", "type", "identifier"), drop = FALSE]
      }
    })
    showNotification(sprintf("Detected %d item(s).", nrow(rv$doc$findings %||% data.frame())),
                     type = "message")
  })

  observeEvent(input$btn_doc_redact, {
    req(rv$doc)
    d <- rv$doc
    have_proj <- !is.null(rv$proj)
    key <- if (have_proj) se_resolve_key(rv$proj$hash_scope, rv$proj)
           else as.raw(sample(0:255, 32L, replace = TRUE))
    outdir <- if (have_proj) se_project_paths(rv$proj$dir)$outputs else tempdir()
    dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
    old <- options(se.detect_postal6 = isTRUE(input$doc_postal6)); on.exit(options(old))
    base <- tools::file_path_sans_ext(basename(d$name))
    det <- list(); ok <- TRUE
    withProgress(message = "Redacting...", {
      if (identical(d$ext, "xml")) {
        outp <- file.path(outdir, paste0(base, "_deid.xml"))
        res <- tryCatch(se_xml_scrub_file(d$path, outp, key = key,
                                          sweep = isTRUE(input$doc_sweep)),
                        error = function(e) { showNotification(conditionMessage(e), type = "error"); NULL })
        if (is.null(res)) { ok <- FALSE } else {
          rv$doc$output <- outp; rv$doc$findings <- res$changes
          rv$doc$waveform_ok <- res$waveform_ok; rv$doc$profile <- res$profile
          det <- list(profile = res$profile, changes = res$n_changes,
                      waveform_ok = res$waveform_ok)
        }
      } else if (identical(d$ext, "pdf")) {
        outp <- file.path(outdir, paste0(base, "_redacted.pdf"))
        res <- tryCatch(se_pdf_redact(d$path, outp,
                                      dpi = as.integer(input$doc_dpi %||% 150L),
                                      force_ocr = isTRUE(input$doc_force_ocr)),
                        error = function(e) { showNotification(conditionMessage(e), type = "error"); NULL })
        if (is.null(res)) { ok <- FALSE } else {
          rv$doc$output <- outp; rv$doc$findings <- res$findings
          rv$doc$waveform_ok <- NA; rv$doc$profile <- paste(unique(res$methods), collapse = ",")
          det <- list(pages = res$pages, boxes = res$n_boxes, verified = res$verified,
                      methods = paste(unique(res$methods), collapse = ","))
        }
      } else ok <- FALSE
    })
    req(ok)
    if (have_proj) {
      rv$proj <- se_register_input(rv$proj, d$path, actor = input$actor)  # register source
      se_manifest_write(rv$proj)                                          # picks up output too
      se_audit_append(se_project_paths(rv$proj$dir)$audit,
                      if (identical(d$ext, "xml")) "xml_scrub" else "pdf_redact",
                      input$actor,
                      c(list(file = basename(d$name), output = basename(rv$doc$output),
                             out_sha256 = substr(se_sha256_file(rv$doc$output), 1, 16)), det))
    }
    msg <- sprintf("Wrote %s.", basename(rv$doc$output))
    if (isFALSE(rv$doc$waveform_ok)) {
      showNotification(paste(msg, "WARNING: waveform-preservation guard FAILED."), type = "error")
    } else showNotification(msg, type = "message")
  })

  output$doc_status <- renderUI({
    d <- rv$doc
    if (is.null(d) || is.null(d$output)) return(NULL)
    wf <- if (isTRUE(d$waveform_ok)) span(class = "badge bg-success ms-1", "waveform preserved")
          else if (isFALSE(d$waveform_ok)) span(class = "badge bg-danger ms-1", "WAVEFORM GUARD FAILED")
          else NULL
    div(class = "mt-2", tags$b("Wrote: "), basename(d$output), wf,
        if (!is.null(rv$proj)) div(class = "small text-muted", "Saved to project outputs/ and logged in the audit trail.")
        else div(class = "small text-muted", "No project open — saved to a temp file for download only (not logged)."))
  })

  output$doc_findings <- renderDT({
    d <- rv$doc
    if (is.null(d) || is.null(d$findings) || !nrow(d$findings))
      return(datatable(data.frame(message = "Load a document, then Detect or Redact.")))
    datatable(d$findings, options = list(scrollX = TRUE, pageLength = 10), rownames = FALSE)
  })

  output$dl_doc <- downloadHandler(
    filename = function() basename(rv$doc$output %||% "redacted_output"),
    content = function(file) { req(rv$doc$output); file.copy(rv$doc$output, file, overwrite = TRUE) })

  # BATCH · run the same pipelines over many files
  observeEvent(input$btn_batch, {
    req(rv$proj); p <- se_project_paths(rv$proj$dir)
    plan <- se_batch_plan(strsplit(input$batch_dir %||% "", ";")[[1]],
                          recursive = isTRUE(input$batch_recursive))
    if (!nrow(plan)) { showNotification("No files found.", type="warning"); return() }
    withProgress(message = "Running batch...", value = 0, {
      res <- se_batch_run(rv$proj, plan,
        opts = list(actor = input$actor, workers = as.integer(input$batch_workers %||% 1L),
                    force = isTRUE(input$batch_force)),
        progress = function(i, n, f) setProgress(value = i/n, detail = sprintf("%d/%d %s", i, n, f)))
      se_batch_write_summary(res); rv$proj <- res$project; rv$batch <- res
    })
    showNotification(sprintf("Batch: %d ok, %d error, %d skipped.",
      rv$batch$totals$ok, rv$batch$totals$error, rv$batch$totals$skipped), type="message")
  })
  output$batch_tbl <- renderDT({
    req(rv$batch)
    datatable(rv$batch$items, options = list(scrollX = TRUE, pageLength = 15), rownames = FALSE)
  })
  output$dl_batch_summary <- downloadHandler(
    filename = function() paste0(rv$proj$name %||% "project", "_batch_summary.csv"),
    content  = function(file) data.table::fwrite(rv$batch$items, file))
}

shinyApp(ui, server)
