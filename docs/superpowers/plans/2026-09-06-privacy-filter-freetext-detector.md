# Privacy Filter Free-Text Detector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OpenAI Privacy Filter the default air-gapped free-text PII detector (out-of-process via ONNX), add an optional interval-preserving `date_shift` transform, and make free-text redaction reviewable so no detector can silently over-redact.

**Architecture:** A new `pf` mode in the existing out-of-process Python engine (`run_engine.py`) runs the exported Privacy Filter ONNX graph via `onnxruntime` + `tokenizers` (no torch/transformers at runtime), decodes BIOES spans, and maps PF labels to our identifier ids. R (`engine_py.R`) gains `se_pf_config`/`se_pf_scan` and includes PF in `se_detect_freetext` by default. Free-text redaction moves from a blind rules-only re-scan to a gated re-scan (rules + optional PF) driven by review decisions carried on the `policy` object, so it stays correct under the chunked/resumable engine. `deidentify.R` gains `se_shift_date` and `se_redact_freetext_spans`. Deterministic rules stay primary for NRIC/FIN/MRN.

**Tech Stack:** R 4.5.2 + Shiny; bundled CPython (out-of-process); `onnxruntime` + `tokenizers`; `openssl` (HMAC-SHA256) for the keyed date offset. PowerShell packaging toolchain.

**Spec:** `docs/superpowers/specs/2026-09-06-privacy-filter-freetext-detector-design.md`

---

## House conventions (read before starting)

- **The repo commits NO tests.** Every "test" step below writes a small self-test **script file into the scratchpad** and runs it. Do **not** add files under `tests/` or commit test files.
- **Never use `Rscript -e "<long multiline>"`** — it segfaults on this machine. Write the script to a `.R` file in the scratchpad and run the file.
- Scratchpad dir (call it `$SCRATCH`): `C:\Users\lauye\AppData\Local\Temp\claude\C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932\8ccd5522-a88b-42ac-8439-bd1a6ff18933\scratchpad`
- Rscript: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "<scriptfile>"` (loads core via `source("app/global.R")`).
- Run all commands from the worktree root: `C:\Users\lauye\Downloads\structured_deidentification\.claude\worktrees\shiny-deidentification-app-6a7932`.
- `se_` prefix, snake_case. Match surrounding comment density/idiom.
- **Air-gap:** no runtime network, ever. **AV:** keep unsigned exes out of the default bundle. **Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. **Do NOT stage `.claude/`.** **ASK before pushing.**
- PowerShell 5.1: loop vars are case-insensitive (don't shadow params); `Set-Content -Encoding utf8` writes a BOM that breaks Rscript → use `ascii`.

## File structure

- **Create** `app/python/detect_pf.py` — PF ONNX detector: `_base_label`, `_decode_bioes`, `_pick_onnx`, `_load_id2label`, `pf_scan`. One responsibility: text → PF spans in our schema. Fails closed to `[]`.
- **Modify** `app/python/run_engine.py` — add `pf` mode, add PF/onnx to `_probe`, add `pf` to the network-forbidden set.
- **Modify** `app/R/engine_py.R` — `se_pf_config`, `se_pf_scan`, extend `se_py_probe` (`$onnx`,`$pf`) and `se_py_status_text`; add `use_pf=TRUE` and `start`/`end`/`identifier` columns to `se_detect_freetext`.
- **Modify** `app/R/deidentify.R` — `se_shift_date`, `date_shift` branch + crosswalk reversibility; `se_redact_freetext_spans`; gated `redact_freetext` branch reading `policy$freetext_opts`.
- **Modify** `app/app.R` — PF toggle in Detect tab; selectable findings table + min-conf slider + per-type checkboxes → `rv$ft_rejects`; `date_shift` policy options; `build_policy()` writes `freetext_opts`.
- **Modify** `app/R/batch.R`, `app/batch_cli.R` — `--pf/--no-pf`, `--ft-min-conf`, `--date-shift/--shift-window/--shift-subject-col`.
- **Modify** `tools/build_bundle.ps1` (+ `tools/check_closure.ps1` note) — bundle `onnxruntime`+`tokenizers`+`models/pf/`, exclude `bin/llama`+GGUF, prune spaCy model by default.
- **Modify** `docs/packaging.md`, `CLAUDE.md`, `docs/roadmap.md` — new default documented.

---

## Task 0: Prerequisite — fetch the Privacy Filter ONNX model (build laptop, online)

**Files:** none in-repo. Downloads to `$SCRATCH/pf` for testing; the packaged copy is produced in Task 10.

The build laptop may be online; the runtime never is. Download the exported ONNX + tokenizer via `curl.exe` (Schannel — the bundled/uv CPython's OpenSSL fails TLS with `no OPENSSL_Applink`).

- [ ] **Step 1: Download the model files**

Run (PowerShell, from anywhere):

```
$dst = "C:\Users\lauye\AppData\Local\Temp\claude\C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932\8ccd5522-a88b-42ac-8439-bd1a6ff18933\scratchpad\pf"
New-Item -ItemType Directory -Force $dst | Out-Null
$base = "https://huggingface.co/openai/privacy-filter/resolve/main"
foreach ($f in @("config.json","tokenizer.json","onnx/model_fp16.onnx")) {
  $out = Join-Path $dst (Split-Path $f -Leaf)
  curl.exe -L --ssl-no-revoke -o $out "$base/$f"
}
```

Expected: `config.json`, `tokenizer.json`, `model_fp16.onnx` present in `$SCRATCH\pf`. (If `model_fp16.onnx` has a sidecar `model_fp16.onnx_data`, download it too — check the repo file listing. If the exact repo path differs, list the repo tree first and adjust `$f`.)

- [ ] **Step 2: Verify the files load offline**

Write `$SCRATCH\pf_smoke.py`:

```python
import os, sys
d = os.path.join(os.path.dirname(__file__), "pf")
import onnxruntime as ort
from tokenizers import Tokenizer
import json
sess = ort.InferenceSession(os.path.join(d, "model_fp16.onnx"),
                            providers=["CPUExecutionProvider"])
tok = Tokenizer.from_file(os.path.join(d, "tokenizer.json"))
cfg = json.load(open(os.path.join(d, "config.json"), encoding="utf-8"))
print("inputs:", [i.name for i in sess.get_inputs()])
print("labels:", cfg.get("id2label"))
enc = tok.encode("Contact John Tan at john@example.com")
print("n_tokens:", len(enc.ids), "offsets[:5]:", enc.offsets[:5])
```

Run with whatever Python has `onnxruntime`+`tokenizers` on the build laptop (e.g. the venv used in the A/B, or install into a scratch venv). Expected: prints the model input names (typically `input_ids`, `attention_mask`), the `id2label` map (labels include `private_person`, `private_email`, …), and a non-empty token/offset list. **Record the exact input names and label strings** — Tasks 1–2 rely on them.

No commit (scratchpad only).

---

## Task 1: `detect_pf.py` — BIOES span decoder (pure, model-free)

**Files:**
- Create: `app/python/detect_pf.py`
- Test: `$SCRATCH/test_decode.py`

- [ ] **Step 1: Write the failing test**

Write `$SCRATCH/test_decode.py`:

```python
import importlib.util, os
spec = importlib.util.spec_from_file_location(
    "detect_pf", os.path.join(os.getcwd(), "app", "python", "detect_pf.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

id2label = {0: "O", 1: "B-private_person", 2: "I-private_person",
            3: "E-private_person", 4: "S-private_email"}
# tokens:      John(0-4)      Tan(5-8)        <special>   x@y(9-12)
offsets = [(0, 4), (5, 8), (0, 0), (9, 12)]
labels  = [1,       3,       0,       4]
spans = m._decode_bioes(labels, offsets, id2label)
assert spans == [("private_person", 0, 8), ("private_email", 9, 12)], spans

# base-label stripping
assert m._base_label("B-private_person") == "private_person"
assert m._base_label("private_date") == "private_date"
assert m._base_label("O") == "O"
print("OK decode")
```

- [ ] **Step 2: Run to verify it fails**

Run: `python "$SCRATCH\test_decode.py"` (any Python 3).
Expected: FAIL — `detect_pf.py` does not exist / `_decode_bioes` undefined.

- [ ] **Step 3: Create `app/python/detect_pf.py` with the decoder**

```python
"""detect_pf.py — OpenAI Privacy Filter free-text PII detector, run OUT-OF-PROCESS.

Loads the model OpenAI exported to ONNX (openai/privacy-filter, Apache-2.0) and
runs it through onnxruntime + tokenizers — NO torch/transformers at runtime. A
bidirectional token classifier: one forward pass -> per-token label ids ->
BIOES/BIO span decode -> map PF labels to our identifier ids.

Called by run_engine.py in the `pf` mode (network hard-disabled). Fails closed:
any missing library/model or any per-text error yields an empty result so the
caller falls back to rules-only. Emits the app's free-text span schema with
1-based, inclusive `start`/`end` (matching se_scan_text in detect_r.R).
"""
import os
import json


# PF base label -> (our identifier id, our type). NRIC/FIN/MRN/postal are NOT PF
# categories — the deterministic rules own those (see detect_r.R).
_PF_MAP = {
    "private_person": ("name", "name"),
    "person": ("name", "name"),
    "private_address": ("address", "address"),
    "address": ("address", "address"),
    "private_email": ("email", "email"),
    "email": ("email", "email"),
    "private_phone": ("phone", "phone"),
    "phone": ("phone", "phone"),
    "private_date": ("dob", "date"),
    "date": ("dob", "date"),
    "private_url": ("other_id", "url"),
    "url": ("other_id", "url"),
    "account_number": ("other_id", "account"),
    "secret": ("other_id", "secret"),
}


def _base_label(lab):
    """Strip a leading BIOES/IOB2 prefix (B- I- E- S- U-) to the base label."""
    if lab in ("O", "o", "", None):
        return "O"
    if len(lab) > 2 and lab[1] == "-" and lab[0].upper() in "BIESU":
        return lab[2:]
    return lab


def _decode_bioes(label_ids, offsets, id2label):
    """Merge per-token predictions into character spans. Robust to BIO/BIOES:
    key on the base label and merge consecutive same-base tokens whose char
    offsets are contiguous (gap <= 1). Special/padding tokens have offset (a==b)
    and are skipped. Returns [(base, start, end), ...] with Python [start, end)."""
    spans = []
    cur = None  # [base, start, end]
    for (a, b), lid in zip(offsets, label_ids):
        if a == b:                      # special / padding token
            continue
        base = _base_label(id2label.get(lid, id2label.get(str(lid), "O")))
        if base == "O":
            if cur:
                spans.append(tuple(cur)); cur = None
            continue
        if cur and cur[0] == base and a <= cur[2] + 1:
            cur[2] = b
        else:
            if cur:
                spans.append(tuple(cur))
            cur = [base, a, b]
    if cur:
        spans.append(tuple(cur))
    return spans
```

- [ ] **Step 4: Run to verify it passes**

Run: `python "$SCRATCH\test_decode.py"`
Expected: `OK decode`

- [ ] **Step 5: Commit**

```bash
git add app/python/detect_pf.py
git commit -m "$(printf 'PF detector: BIOES span decoder (pure)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 2: `detect_pf.py` — `pf_scan` (onnxruntime inference + label map)

**Files:**
- Modify: `app/python/detect_pf.py`
- Test: `$SCRATCH/test_pf_scan.py` (needs the model from Task 0)

- [ ] **Step 1: Write the failing test**

Write `$SCRATCH/test_pf_scan.py`:

```python
import importlib.util, os
here = os.getcwd()
spec = importlib.util.spec_from_file_location(
    "detect_pf", os.path.join(here, "app", "python", "detect_pf.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

model_dir = os.path.join(here, "..", "..", "..",  # not used; use scratch path below
                         )
model_dir = r"C:\Users\lauye\AppData\Local\Temp\claude\C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932\8ccd5522-a88b-42ac-8439-bd1a6ff18933\scratchpad\pf"

# fail-closed: bad dir -> []
assert m.pf_scan(["hello"], "C:\\no\\such\\dir") == []

rows = m.pf_scan(["Please call John Tan at john.tan@example.com on 3 Jan 2024.",
                  "Singapore General Hospital, ward 5B."], model_dir)
print(rows)
types = {(r["row"], r["type"]) for r in rows}
assert any(t == (1, "name") for t in types), "should find a name"
assert any(t == (1, "email") for t in types), "should find an email"
# institution should NOT be flagged as a person/address false positive on row 2
assert all(not (r["row"] == 2 and r["match"].startswith("Singapore General"))
           for r in rows), "institution over-redacted"
# schema + 1-based inclusive offsets
r0 = rows[0]
assert set(r0) >= {"row","start","end","match","type","identifier","detector","confidence"}
assert r0["detector"] == "pf" and abs(r0["confidence"] - 0.85) < 1e-9
print("OK pf_scan")
```

- [ ] **Step 2: Run to verify it fails**

Run: `python "$SCRATCH\test_pf_scan.py"` (Python with onnxruntime+tokenizers).
Expected: FAIL — `pf_scan` undefined.

- [ ] **Step 3: Append `pf_scan` + helpers to `app/python/detect_pf.py`**

```python
def _pick_onnx(model_dir):
    for name in ("model_fp16.onnx", "model.onnx", "model_q4f16.onnx", "model_q4.onnx"):
        p = os.path.join(model_dir, name)
        if os.path.isfile(p):
            return p
    for f in sorted(os.listdir(model_dir)):
        if f.endswith(".onnx"):
            return os.path.join(model_dir, f)
    raise FileNotFoundError("no .onnx in " + model_dir)


def _load_id2label(config_path):
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    raw = cfg.get("id2label") or {}
    return {int(k): v for k, v in raw.items()}


def pf_scan(texts, model_dir):
    """texts: list[str]; model_dir: dir with the ONNX model + tokenizer.json +
    config.json. Returns a list of span dicts (1-based inclusive start/end)."""
    if not texts or not model_dir or not os.path.isdir(model_dir):
        return []
    try:
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer
        sess = ort.InferenceSession(_pick_onnx(model_dir),
                                    providers=["CPUExecutionProvider"])
        tok = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
        id2label = _load_id2label(os.path.join(model_dir, "config.json"))
        in_names = [i.name for i in sess.get_inputs()]
    except Exception:
        return []

    out = []
    for ridx, text in enumerate(texts):
        if text is None:
            continue
        text = str(text)
        if not text.strip():
            continue
        try:
            enc = tok.encode(text)
            arr = np.array([enc.ids], dtype=np.int64)
            feeds = {}
            if "input_ids" in in_names:
                feeds["input_ids"] = arr
            if "attention_mask" in in_names:
                feeds["attention_mask"] = np.ones_like(arr)
            if "token_type_ids" in in_names:
                feeds["token_type_ids"] = np.zeros_like(arr)
            logits = sess.run(None, feeds)[0][0]          # (seq_len, num_labels)
            label_ids = logits.argmax(-1).tolist()
            spans = _decode_bioes(label_ids, enc.offsets, id2label)
        except Exception:
            continue
        for base, s, e in spans:
            mapped = _PF_MAP.get(base)
            if not mapped:
                continue
            ident, typ = mapped
            frag = text[s:e]
            if len(frag.strip()) < 1:
                continue
            out.append({"row": ridx + 1, "start": s + 1, "end": e,
                        "match": frag, "type": typ, "identifier": ident,
                        "detector": "pf", "confidence": 0.85})
    return out
```

(If Task 0 Step 2 reported input names other than the three handled here, adjust the `feeds` block accordingly before running.)

- [ ] **Step 4: Run to verify it passes**

Run: `python "$SCRATCH\test_pf_scan.py"`
Expected: prints found spans then `OK pf_scan` (name + email on row 1; institution on row 2 not over-redacted).

- [ ] **Step 5: Commit**

```bash
git add app/python/detect_pf.py
git commit -m "$(printf 'PF detector: pf_scan via onnxruntime + tokenizers (fail-closed)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 3: `run_engine.py` — add the `pf` mode

**Files:**
- Modify: `app/python/run_engine.py`
- Test: `$SCRATCH/test_runner_pf.ps1`

- [ ] **Step 1: Extend `_probe` to report onnx** — replace the `for name in (...)` line and the return dict in `_probe()` (run_engine.py:55-63):

```python
    for name in ("presidio_analyzer", "spacy", "ollama", "requests",
                 "onnxruntime", "tokenizers"):
        try:
            __import__(name)
            out[name] = True
        except Exception:
            out[name] = False
    return {"presidio": out.get("presidio_analyzer", False),
            "spacy": out.get("spacy", False),
            "ollama": out.get("ollama", False) or out.get("requests", False),
            "onnx": out.get("onnxruntime", False) and out.get("tokenizers", False)}
```

- [ ] **Step 2: Add `pf` to the network-forbidden set** — change run_engine.py:75:

```python
    if mode in ("probe", "ner", "pf") or (mode == "llm" and req.get("backend", "") != "ollama"):
        _forbid_network()
```

- [ ] **Step 3: Add the `pf` dispatch branch** — after the `ner` branch (run_engine.py:82-84), insert:

```python
        elif mode == "pf":
            import detect_pf
            result = detect_pf.pf_scan(req.get("texts", []), req.get("model_dir", ""))
```

- [ ] **Step 4: Update the module docstring Modes list** — add under the `ner` line (run_engine.py:16):

```
  pf    : stdin {"texts":[...],"model_dir":.} -> [ span, ... ]   (see detect_pf.py)
```

- [ ] **Step 5: Test end-to-end through the runner**

Write `$SCRATCH/test_runner_pf.ps1`:

```
$py = "python"   # a Python with onnxruntime+tokenizers
$root = "C:\Users\lauye\Downloads\structured_deidentification\.claude\worktrees\shiny-deidentification-app-6a7932"
$md = "C:\Users\lauye\AppData\Local\Temp\claude\C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932\8ccd5522-a88b-42ac-8439-bd1a6ff18933\scratchpad\pf"
$req = @{ texts = @("Call John Tan at john@x.com"); model_dir = $md } | ConvertTo-Json -Compress
# probe
$req | & $py "$root\app\python\run_engine.py" probe
# pf
$req | & $py "$root\app\python\run_engine.py" pf
```

Run it. Expected: probe prints JSON with `"onnx":true`; pf prints a JSON array containing a `name` span and an `email` span with `"detector":"pf"`.

- [ ] **Step 6: Commit**

```bash
git add app/python/run_engine.py
git commit -m "$(printf 'run_engine: add socket-free pf mode + onnx probe\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 4: `engine_py.R` — `se_pf_config`, `se_pf_scan`, probe/status

**Files:**
- Modify: `app/R/engine_py.R`
- Test: `$SCRATCH/test_pf_r.R`

- [ ] **Step 1: Add `se_pf_config` + `se_pf_scan`** — insert after `se_py_scan` (engine_py.R:104), before `se_py_status_text`:

```r
#' Privacy Filter model directory, discovered passively (file existence only —
#' never runs anything, never touches the network). options(se.pf_dir) /
#' SE_PF_DIR, else <bundle>/models/pf/. `available` requires an .onnx plus the
#' tokenizer and config next to it.
se_pf_config <- function() {
  dir <- getOption("se.pf_dir", Sys.getenv("SE_PF_DIR", ""))
  if (!nzchar(dir)) dir <- file.path(se_bundle_root(), "models", "pf")
  has_model <- dir.exists(dir) &&
    length(list.files(dir, pattern = "\\.onnx$", ignore.case = TRUE)) > 0L &&
    file.exists(file.path(dir, "tokenizer.json")) &&
    file.exists(file.path(dir, "config.json"))
  list(dir = dir, available = isTRUE(has_model))
}

#' Privacy Filter scan of a character vector via the bundled Python, out-of-
#' process (ONNX). Returns the findings span schema (row, start, end, match,
#' type, identifier, detector, confidence) or an empty frame. Fails closed.
se_pf_scan <- function(texts) {
  if (is.null(se_py_binary())) return(.se_empty_ner())
  cfg <- se_pf_config()
  if (!isTRUE(cfg$available)) return(.se_empty_ner())
  r <- .se_py_run("pf", list(texts = as.character(texts), model_dir = cfg$dir))
  if (is.null(r) || !is.data.frame(r) || !nrow(r)) .se_empty_ner() else r
}
```

- [ ] **Step 2: Extend `se_py_probe`** — inside `se_py_probe` (engine_py.R:73-94), after the presidio/spacy block (after line 81, the `}` closing the else), add before `cfg <- se_llm_config()`:

```r
  st$onnx <- if (is.null(res)) FALSE else isTRUE(res$onnx)
  st$pf   <- isTRUE(st$onnx) && isTRUE(se_pf_config()$available)
```

Also add `onnx = NA, pf = NA` to the `st` list initialiser in `se_py_status` (engine_py.R:65-66), so the fields exist before a probe:

```r
             presidio = NA, spacy = NA, ollama = NA, onnx = NA, pf = NA,
             llm = NA, llm_backend = NA_character_)
```

- [ ] **Step 3: Mention PF in `se_py_status_text`** — in `se_py_status_text` (engine_py.R:111-115), extend the `tail` when PF is ready:

```r
    tail <- paste0(
      if (isTRUE(st$pf)) " · Privacy Filter ready." else "",
      if (isTRUE(st$llm)) paste0(" · local LLM (", st$llm_backend, ") available.") else
      if (!isTRUE(st$pf)) "." else "")
    return(paste0("Python NER: Presidio + spaCy ready", tail))
```

- [ ] **Step 4: Self-test config + fail-closed scan**

Write `$SCRATCH/test_pf_r.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))
# no model configured -> unavailable, empty, no error
options(se.pf_dir = "C:/no/such/dir")
stopifnot(isFALSE(se_pf_config()$available))
r <- se_pf_scan(c("hello", "world"))
stopifnot(is.data.frame(r), nrow(r) == 0L)
# point at the scratch model dir -> available TRUE (files exist)
options(se.pf_dir = "C:/Users/lauye/AppData/Local/Temp/claude/C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932/8ccd5522-a88b-42ac-8439-bd1a6ff18933/scratchpad/pf")
stopifnot(isTRUE(se_pf_config()$available))
cat("OK engine_py pf config\n")
```

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_pf_r.R"`
Expected: `OK engine_py pf config` (no error; empty frame for the bad dir; available TRUE for the scratch dir). A full `se_pf_scan` returning rows also requires the bundled `bin/python` with onnxruntime — validated at Task 10.

- [ ] **Step 5: Commit**

```bash
git add app/R/engine_py.R
git commit -m "$(printf 'engine_py: se_pf_config + se_pf_scan + pf probe/status\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 5: `se_detect_freetext` — carry offsets + include PF by default

**Files:**
- Modify: `app/R/engine_py.R` (se_detect_freetext, lines 258-296)
- Test: `$SCRATCH/test_detect_ft.R`

- [ ] **Step 1: Write the failing test**

Write `$SCRATCH/test_detect_ft.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))
options(se.pf_dir = "C:/no/such/dir")   # PF unavailable -> rules only, still fine
df <- data.frame(notes = c("NRIC S1234567D on file", "no pii here"),
                 stringsAsFactors = FALSE)
ff <- se_detect_freetext(df, ftcols = "notes", use_pf = FALSE)
stopifnot(all(c("row","column","start","end","match","type","identifier",
                "confidence","detector") %in% names(ff)))
stopifnot(nrow(ff) >= 1L, any(ff$type == "national_id" | ff$identifier == "national_id"))
stopifnot(!any(is.na(ff$start)), !any(is.na(ff$end)))
cat("OK detect_freetext schema\n")
```

- [ ] **Step 2: Run to verify it fails**

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_detect_ft.R"`
Expected: FAIL — findings currently lack `start`/`end`/`identifier` columns.

- [ ] **Step 3: Rewrite `se_detect_freetext`** (engine_py.R:260-296) to add `use_pf` and offsets:

```r
se_detect_freetext <- function(df, ftcols = se_freetext_columns(names(df)),
                               use_pf = TRUE, use_ner = FALSE, use_llm = FALSE,
                               detectors = se_detectors()) {
  cols <- intersect(ftcols, names(df))
  out <- list()
  add <- function(row, column, start, end, match, type, identifier,
                  confidence, detector) {
    if (length(match))
      out[[length(out) + 1L]] <<- data.frame(
        row = row, column = column, start = start, end = end, match = match,
        type = type, identifier = identifier, confidence = confidence,
        detector = detector, stringsAsFactors = FALSE)
  }
  for (cn in cols) {
    vals <- as.character(df[[cn]])
    # deterministic rules, per cell
    for (i in seq_along(vals)) {
      sp <- se_scan_text(vals[i], detectors)
      if (nrow(sp)) add(i, cn, sp$start, sp$end, sp$match, sp$type,
                        sp$identifier, sp$confidence, sp$detector)
    }
    # Privacy Filter (default), whole column vector (guards itself when absent)
    if (isTRUE(use_pf)) {
      ps <- tryCatch(se_pf_scan(vals), error = function(e) NULL)
      if (!is.null(ps) && nrow(ps))
        add(ps$row, cn, ps$start, ps$end, ps$match, ps$type,
            ps$identifier, ps$confidence, ps$detector)
    }
    # legacy offline NER (opt-in)
    if (isTRUE(use_ner)) {
      ns <- tryCatch(se_py_scan(vals), error = function(e) NULL)
      if (!is.null(ns) && nrow(ns))
        add(ns$row, cn, ns$start, ns$end, ns$match, ns$type,
            ns$identifier, ns$confidence, ns$detector)
    }
    # legacy local LLM (opt-in)
    if (isTRUE(use_llm)) {
      ls <- tryCatch(se_llm_scan(vals), error = function(e) NULL)
      if (!is.null(ls) && nrow(ls))
        add(ls$row, cn, ls$start, ls$end, ls$match, ls$type,
            ls$identifier, ls$confidence, ls$detector)
    }
  }
  res <- if (length(out)) do.call(rbind, out) else
    data.frame(row = integer(0), column = character(0), start = integer(0),
               end = integer(0), match = character(0), type = character(0),
               identifier = character(0), confidence = numeric(0),
               detector = character(0), stringsAsFactors = FALSE)
  se_dedup_findings(res)
}
```

(`se_dedup_findings` subsets rows and keeps all columns, so the new columns pass through unchanged.)

- [ ] **Step 4: Run to verify it passes**

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_detect_ft.R"`
Expected: `OK detect_freetext schema`

- [ ] **Step 5: Commit**

```bash
git add app/R/engine_py.R
git commit -m "$(printf 'se_detect_freetext: carry start/end/identifier; PF on by default\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 6: `deidentify.R` — `se_redact_freetext_spans` + gated redaction

**Files:**
- Modify: `app/R/deidentify.R`
- Test: `$SCRATCH/test_redact.R`

- [ ] **Step 1: Write the failing test**

Write `$SCRATCH/test_redact.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))

# pure span applier
spans <- data.frame(start = c(6L), end = c(12L), type = c("name"),
                    stringsAsFactors = FALSE)
stopifnot(se_redact_freetext_spans("Call Johnny now", spans) == "Call [NAME] now")
stopifnot(se_redact_freetext_spans("nothing", spans[0, ]) == "nothing")

# gated redaction through the table engine, rules-only, with a reject.
# S1234567D is a CHECKSUM-VALID NRIC (conf 0.99, above the 0.5 threshold); the
# detector `type` for NRIC is "nric" (identifier "national_id"), so the tag is
# "[NRIC]" and the reject content-key uses type "nric".
df <- data.frame(notes = c("NRIC S1234567D and name Alice"), stringsAsFactors = FALSE)
key <- as.raw(1:32)
pol <- list(columns = list(notes = list(identifier = NA, action = "redact_freetext",
                                        options = list())),
            freetext_opts = list(use_pf = FALSE, min_conf = 0.5,
                                  types = NULL, rejects = character(0)))
r1 <- se_deidentify_table(df, pol, key)$data$notes
stopifnot(grepl("\\[NRIC\\]", r1))   # NRIC redacted by rule

# reject the NRIC value by content key (column \t type \t tolower(match)) -> survives
rej <- paste("notes", "nric", tolower("S1234567D"), sep = "\t")
pol$freetext_opts$rejects <- rej
r2 <- se_deidentify_table(df, pol, key)$data$notes
stopifnot(grepl("S1234567D", r2))    # rejected span NOT redacted
cat("OK redact gating\n")
```

- [ ] **Step 2: Run to verify it fails**

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_redact.R"`
Expected: FAIL — `se_redact_freetext_spans` undefined; `freetext_opts` ignored.

- [ ] **Step 3: Add `se_redact_freetext_spans`** — insert in deidentify.R after `se_redact_freetext_value` (after line 91):

```r
#' Redact a single free-text cell using a SUPPLIED span set (already filtered to
#' accepted spans above the confidence threshold). Right-to-left by offset so
#' positions stay valid; postal codes masked (keep sector), everything else
#' replaced by a typed tag. Pure — no detector call, no re-scan.
#' @param spans data.frame with columns start, end, type (1-based, inclusive).
se_redact_freetext_spans <- function(text, spans) {
  if (is.na(text) || !nzchar(text)) return(text)
  if (is.null(spans) || !nrow(spans)) return(text)
  spans <- se_dedup_overlaps(spans)
  spans <- spans[order(-spans$start), , drop = FALSE]
  out <- text
  for (i in seq_len(nrow(spans))) {
    s <- spans$start[i]; e <- spans$end[i]
    if (is.na(s) || is.na(e) || s < 1L || e < s || s > nchar(out)) next
    matched <- substr(out, s, e)
    repl <- if (identical(spans$type[i], "postal")) se_mask_postal(matched)
            else paste0("[", toupper(spans$type[i]), "]")
    out <- paste0(substr(out, 1, s - 1L), repl, substr(out, e + 1L, nchar(out)))
  }
  out
}
```

- [ ] **Step 4: Replace the `redact_freetext` branch** in `se_deidentify_table` (deidentify.R:138-139) with the gated version:

```r
      "redact_freetext" = {
        fo <- policy$freetext_opts %||% NULL
        if (is.null(fo)) {
          # no policy-level review options -> legacy blind re-scan (ad-hoc use)
          vapply(orig, se_redact_freetext_value, character(1),
                 detectors = detectors, USE.NAMES = FALSE)
        } else {
          min_conf    <- fo$min_conf %||% 0.5
          types_allow <- fo$types    %||% NULL          # NULL = all types
          rejects     <- fo$rejects  %||% character(0)  # "col\ttype\ttolower(match)"
          pf_by_row <- NULL
          if (isTRUE(fo$use_pf)) {
            ps <- tryCatch(se_pf_scan(orig), error = function(e) NULL)
            if (!is.null(ps) && nrow(ps)) pf_by_row <- split(ps, ps$row)
          }
          keepcols <- c("start", "end", "match", "type", "identifier",
                        "detector", "confidence")
          vapply(seq_along(orig), function(i) {
            cell <- orig[i]
            if (is.na(cell) || !nzchar(cell)) return(cell)
            sp <- se_scan_text(cell, detectors)[, keepcols, drop = FALSE]
            if (!is.null(pf_by_row)) {
              pr <- pf_by_row[[as.character(i)]]
              if (!is.null(pr) && nrow(pr))
                sp <- rbind(sp, pr[, keepcols, drop = FALSE])
            }
            if (!nrow(sp)) return(cell)
            sp <- sp[sp$confidence >= min_conf, , drop = FALSE]
            if (!is.null(types_allow))
              sp <- sp[sp$type %in% types_allow, , drop = FALSE]
            if (length(rejects) && nrow(sp)) {
              kk <- paste(cn, sp$type, tolower(sp$match), sep = "\t")
              sp <- sp[!(kk %in% rejects), , drop = FALSE]
            }
            if (!nrow(sp)) return(cell)
            se_redact_freetext_spans(cell, sp)
          }, character(1), USE.NAMES = FALSE)
        }
      },
```

- [ ] **Step 5: Run to verify it passes**

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_redact.R"`
Expected: `OK redact gating`

- [ ] **Step 6: Commit**

```bash
git add app/R/deidentify.R
git commit -m "$(printf 'deidentify: reviewable gated free-text redaction (spans + policy opts)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 7: `deidentify.R` — `se_shift_date` transform + crosswalk

**Files:**
- Modify: `app/R/deidentify.R`
- Test: `$SCRATCH/test_shift.R`

- [ ] **Step 1: Write the failing test**

Write `$SCRATCH/test_shift.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))
key <- as.raw(1:32)

x  <- c("2020-01-01", "2020-01-31", "01/03/2020")
id <- c("P1", "P1", "P2")
s1 <- se_shift_date(x, key, salt = "dob", subject_id = id, window = 365L)
# parseable -> ISO output, not the original
stopifnot(all(grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", s1)))
# same subject -> interval preserved (Jan 1 to Jan 31 = 30 days)
d <- as.Date(s1)
stopifnot(as.integer(d[2] - d[1]) == 30L)
# deterministic
stopifnot(identical(s1, se_shift_date(x, key, "dob", id, 365L)))
# different key -> (very likely) different offset
s2 <- se_shift_date(x, as.raw(32:1), "dob", id, 365L)
stopifnot(!identical(s1[1], s2[1]))
# unparseable -> [DATE]; NA -> NA
stopifnot(se_shift_date("not a date", key, "dob", NULL, 365L) == "[DATE]")
stopifnot(is.na(se_shift_date(NA_character_, key, "dob", NULL, 365L)))
cat("OK shift_date\n")

# crosswalk reversibility via the table engine
df  <- data.frame(dob = c("2000-05-10", "2000-05-10")) 
pol <- list(columns = list(dob = list(identifier = "dob", action = "generalize",
              options = list(generalize = "date_shift", shift_window = 365L))))
res <- se_deidentify_table(df, pol, key)
stopifnot(nrow(res$crosswalk) >= 1L)
stopifnot(all(c("column","original","token") %in% names(res$crosswalk)))
stopifnot("2000-05-10" %in% res$crosswalk$original)
cat("OK shift_date crosswalk\n")
```

- [ ] **Step 2: Run to verify it fails**

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_shift.R"`
Expected: FAIL — `se_shift_date` undefined.

- [ ] **Step 3: Add `se_shift_date`** — insert in deidentify.R after `se_generalize_date` (after line 25):

```r
#' Consistent, keyed per-subject date shift. The offset (in days) is deterministic
#' from the scope key and the subject id, so every date belonging to one subject
#' moves by the same amount and intervals between a subject's events are preserved.
#' Reversible: the caller records original -> shifted in the AEAD crosswalk.
#' @param x          character/Date vector.
#' @param key        resolved scope key (raw/character).
#' @param salt       per-column salt (namespaces the offset).
#' @param subject_id character vector (recycled) naming the subject per element;
#'                   NULL -> a single dataset-wide offset (still hides absolute
#'                   dates, preserves every interval).
#' @param window     max absolute offset in days; offset in [-window, +window].
se_shift_date <- function(x, key, salt = "", subject_id = NULL, window = 365L) {
  x <- as.character(x)
  n <- length(x)
  d <- suppressWarnings(as.Date(x,
        tryFormats = c("%d/%m/%Y", "%Y-%m-%d", "%m/%d/%Y", "%d-%m-%Y")))
  window <- max(1L, as.integer(window))
  span   <- 2L * window + 1L
  subj   <- if (is.null(subject_id)) rep("_all_", n) else
            rep(as.character(subject_id), length.out = n)
  cache  <- new.env(parent = emptyenv())
  offset_for <- function(sid) {
    dig <- as.raw(openssl::sha256(charToRaw(paste0(salt, "|", sid)), key = key))
    acc <- 0
    for (b in as.integer(dig[1:8])) acc <- (acc * 256 + b) %% span
    acc - window
  }
  out <- rep(NA_character_, n)
  for (i in seq_len(n)) {
    if (is.na(d[i])) {
      if (!is.na(x[i]) && nzchar(x[i])) out[i] <- "[DATE]"
      next
    }
    sid <- subj[i]
    off <- cache[[sid]]
    if (is.null(off)) { off <- offset_for(sid); cache[[sid]] <- off }
    out[i] <- format(d[i] + off, "%Y-%m-%d")
  }
  out
}
```

- [ ] **Step 4: Wire `date_shift` into the engine** — in `se_deidentify_table`, lift `meth` out of the switch and add the branch + reversibility. Replace the `generalize` branch (deidentify.R:129-136) with:

```r
      "generalize" = {
        if (meth %in% c("year","year_month")) se_generalize_date(orig, meth)
        else if (meth == "age_band")   se_generalize_age(orig, opts$width %||% 5L)
        else if (meth == "region")     se_generalize_geo(orig, "region")
        else if (meth == "postal_mask") se_mask_postal(orig, opts$mask_last %||% 3L)
        else if (meth == "date_shift") {
          subj <- if (!is.null(opts$shift_subject_col) &&
                      nzchar(opts$shift_subject_col %||% "") &&
                      (opts$shift_subject_col %in% names(df)))
                    as.character(df[[opts$shift_subject_col]]) else NULL
          se_shift_date(orig, key, salt = salt, subject_id = subj,
                        window = opts$shift_window %||% 365L)
        }
        else orig
      },
```

Immediately BEFORE the `new <- switch(action, ...)` line (deidentify.R:115), add:

```r
    meth <- opts$generalize %||% ndef$generalize %||% "year"
```

- [ ] **Step 5: Record the crosswalk for date_shift** — replace the reversible-mappings guard (deidentify.R:146) so `date_shift` is treated as reversible:

```r
    reversible <- action %in% c("pseudonymize", "fpe") ||
                  (action == "generalize" && identical(meth, "date_shift"))
    if (reversible) {
```

(The block inside — building `crosswalk[[cn]]` from `orig`/`new` — is unchanged; it already records `original`/`token`. For `date_shift` the crosswalk stores original date → shifted date, enabling authorised re-identification.)

- [ ] **Step 6: Run to verify it passes**

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_shift.R"`
Expected: `OK shift_date` then `OK shift_date crosswalk`

- [ ] **Step 7: Commit**

```bash
git add app/R/deidentify.R
git commit -m "$(printf 'deidentify: interval-preserving keyed date_shift (reversible)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 8: `app.R` — PF toggle, reviewable findings, date_shift options

**Files:**
- Modify: `app/app.R`
- Test: `$SCRATCH/test_app_policy.R` (testServer + build_policy shape) + a manual browser check

- [ ] **Step 1: Add the PF toggle + review controls to the Detect tab UI** — in the Detect `nav_panel` (app.R:125-130), put PF first and add the review controls. Replace the `div(class = "mt-2", ...)` block (app.R:125-130) with:

```r
      div(class = "mt-2",
        checkboxInput("use_pf",
          "Enable Privacy Filter (free-text PII) — recommended", value = TRUE),
        sliderInput("ft_min_conf", "Redaction confidence threshold",
          min = 0.1, max = 0.99, value = 0.5, step = 0.05),
        # Types are the detector `type` vocabulary (detect_r.R se_detectors) UNION
        # the PF types (name, address, secret). ALL selected by default so nothing
        # is silently left un-redacted; UNCHECK a type to stop redacting it.
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
```

- [ ] **Step 2: Add a hint under the findings table** — in the Detect tab, change the free-text card (app.R:142-143) to include a reject hint:

```r
      card(card_header("Free-text PII found in notes-like columns"),
        div(class = "small text-muted mb-1",
            "Select any row to EXCLUDE that value from redaction (reject). ",
            "Everything shown at or above the confidence threshold, and of a ",
            "selected type, will be redacted; the reviewer sees the diff before release."),
        DTOutput("freetext_findings")))
```

- [ ] **Step 3: Pass `use_pf` into detection** — in the detect observer (app.R:395-396), change the `se_detect_freetext` call:

```r
      ff <- se_detect_freetext(rv$df,
              use_pf = isTRUE(input$use_pf),
              use_ner = isTRUE(input$use_ner), use_llm = isTRUE(input$use_llm))
```

And add `pf = isTRUE(input$use_pf)` to the audit `list(...)` (app.R:401-403).

- [ ] **Step 4: Make the findings table selectable** — replace `output$freetext_findings` (app.R:414-417):

```r
  output$freetext_findings <- renderDT({
    if (is.null(rv$findings)) return(datatable(data.frame(message = "Run detection.")))
    datatable(rv$findings, selection = "multiple",
              options = list(scrollX = TRUE, pageLength = 10), rownames = FALSE)
  })
```

- [ ] **Step 5: Collect rejects from selected rows** — add near the other observers (e.g. after the detect observer, app.R:404):

```r
  observeEvent(input$freetext_findings_rows_selected, ignoreNULL = FALSE, {
    sel <- input$freetext_findings_rows_selected
    if (is.null(rv$findings) || is.null(sel) || !length(sel)) { rv$ft_rejects <- character(0); return() }
    f <- rv$findings[sel, , drop = FALSE]
    rv$ft_rejects <- paste(f$column, f$type, tolower(f$match), sep = "\t")
  })
```

Add `ft_rejects = character(0)` to the `reactiveValues(...)` initialiser (app.R:307 area, where `findings = NULL` is set).

- [ ] **Step 6: Write `freetext_opts` in `build_policy`** — in `build_policy` (app.R:447-459), before `list(columns = cols, freetext_columns = ftcols)`, add:

```r
    types_sel <- input$ft_types %||% NULL
    freetext_opts <- list(use_pf = isTRUE(input$use_pf),
                          min_conf = as.numeric(input$ft_min_conf %||% 0.5),
                          types = types_sel,
                          rejects = rv$ft_rejects %||% character(0))
```

and return:

```r
    list(columns = cols, freetext_columns = ftcols, freetext_opts = freetext_opts)
```

- [ ] **Step 7: Add `date_shift` to the policy UI options** — the Policy tab uses `se_action_choices()` and per-identifier `generalize` from `se_identifier()`. To expose date_shift + its params without a full per-column form rebuild, add three global controls to the Policy card (app.R:148-154), after the buttons `div`:

```r
      div(class = "mt-2 p-2 border rounded",
        tags$b("Date handling (applies to columns whose action is Generalize on a date/DOB)"),
        selectInput("date_method", "Date generalise method",
          c("Year only" = "year", "Year-month (drop day)" = "year_month",
            "Date-shift (keep intervals)" = "date_shift"), selected = "year"),
        numericInput("shift_window", "Date-shift window (± days)", value = 365, min = 1),
        selectInput("shift_subject_col", "Date-shift subject column (optional)",
          choices = c("(dataset-wide)" = ""), selected = "")),
```

Populate `shift_subject_col` choices when data loads — add an observer:

```r
  observeEvent(rv$df, {
    updateSelectInput(session, "shift_subject_col",
      choices = c("(dataset-wide)" = "", stats::setNames(names(rv$df), names(rv$df))))
  })
```

Then in `build_policy` (Step 6), when writing each column's `options`, merge the date-shift params for generalize columns:

```r
      opts <- list(fpe_mode = se_identifier(ident)$fpe_mode,
                   generalize = if (act == "generalize") input$date_method
                                else se_identifier(ident)$generalize)
      if (identical(input$date_method, "date_shift")) {
        opts$shift_window <- as.integer(input$shift_window %||% 365L)
        opts$shift_subject_col <- input$shift_subject_col %||% ""
      }
      cols[[cn]] <- list(identifier = if (ident=="keep") NA else ident,
                         action = act, options = opts)
```

(Replace the existing `cols[[cn]] <- list(...)` at app.R:454-456 with the above.)

- [ ] **Step 8: testServer smoke for the policy shape**

Write `$SCRATCH/test_app_policy.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))
library(shiny)
# Load the app object; app.R defines ui/server. Source it to get `server`.
# (If app.R calls shinyApp() at top level, wrap via shiny::testServer on that app.)
app <- shiny::shinyAppFile("app/app.R")
shiny::testServer(app, {
  session$setInputs(use_pf = TRUE, ft_min_conf = 0.6,
                    ft_types = c("name","email"), date_method = "date_shift",
                    shift_window = 200, shift_subject_col = "")
  # simulate a loaded frame + a build_policy call path is app-specific; at minimum
  # assert the inputs are wired without error.
  stopifnot(isTRUE(input$use_pf), input$ft_min_conf == 0.6)
})
cat("OK app inputs wired\n")
```

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_app_policy.R"`
Expected: `OK app inputs wired`. (If `testServer` can't resolve `build_policy` — it's an internal server closure — this smoke just asserts inputs bind; the redaction/date logic is already covered by Tasks 6–7.)

- [ ] **Step 9: Manual browser check**

Start the app and load the browser:

```
& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" -e "shiny::runApp('app', port=7788)"
```

Use the in-app browser (`mcp__Claude_Browser__navigate` to `http://127.0.0.1:7788`). Confirm: Detect tab shows the PF checkbox (checked), threshold slider, type checkboxes, and an "Advanced" disclosure hiding NER/LLM. Load `samples/`, run detection, select a finding row (it highlights = rejected). Policy tab shows the date-handling controls. No Shiny errors in the console (`mcp__Claude_Browser__read_console_messages`).

- [ ] **Step 10: Commit**

```bash
git add app/app.R
git commit -m "$(printf 'app: PF default toggle, reviewable free-text findings, date_shift policy UI\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 9: Batch runner + CLI flags

**Files:**
- Modify: `app/R/batch.R`, `app/batch_cli.R`
- Test: `$SCRATCH/test_batch_flags.R`

Context: `se_batch_run(proj, plan, opts, progress)` uses `policy <- proj$policy` (batch.R:52) and passes it to `se_deidentify_file` (batch.R:78) — so `policy$freetext_opts` rides through to every chunk unchanged. Batch has **no interactive per-span review**, so `rejects` stays empty; the confidence threshold + per-type policy are the batch controls. `batch_cli.R` parses flags with `getopt(k,d)` / `getflag(k)` and builds an `opts` list (batch_cli.R:22-26).

- [ ] **Step 1: Merge the batch controls into the policy** — in `se_batch_run`, immediately after `policy <- proj$policy` (batch.R:52), add:

```r
  # batch-level free-text redaction controls (no interactive per-span review):
  # the confidence threshold + per-type policy do the gating; rejects stay empty.
  if (!is.null(opts$freetext_opts)) {
    fo <- opts$freetext_opts
    fo$rejects <- character(0)
    policy$freetext_opts <- fo
  }
  # optional interval-preserving date shift on every generalise column
  if (isTRUE(opts$date_shift) && length(policy$columns)) {
    for (cn in names(policy$columns)) {
      spc <- policy$columns[[cn]]
      if (identical(spc$action, "generalize")) {
        spc$options$generalize        <- "date_shift"
        spc$options$shift_window      <- as.integer(opts$shift_window %||% 365L)
        spc$options$shift_subject_col <- opts$shift_subject_col %||% ""
        policy$columns[[cn]] <- spc
      }
    }
  }
```

- [ ] **Step 2: Parse the CLI flags** — in `app/batch_cli.R`, add to the `opts` list passed to `se_batch_run` (batch_cli.R:22-26):

```r
  freetext_opts = list(use_pf = !getflag("--no-pf"),
                       min_conf = as.numeric(getopt("--ft-min-conf", "0.5")),
                       types = NULL, rejects = character(0)),
  date_shift = getflag("--date-shift"),
  shift_window = as.integer(getopt("--shift-window", "365")),
  shift_subject_col = getopt("--shift-subject-col", ""),
```

Update the usage comment (batch_cli.R:2-3) to list `[--no-pf] [--ft-min-conf N] [--date-shift] [--shift-window N] [--shift-subject-col NAME]`.

- [ ] **Step 3: Self-test the option plumbing**

Write `$SCRATCH/test_batch_flags.R`:

```r
setwd("C:/Users/lauye/Downloads/structured_deidentification/.claude/worktrees/shiny-deidentification-app-6a7932")
suppressWarnings(suppressMessages(source("app/global.R")))
SCR <- "C:/Users/lauye/AppData/Local/Temp/claude/C--Users-lauye-Downloads-structured-deidentification--claude-worktrees-shiny-deidentification-app-6a7932/8ccd5522-a88b-42ac-8439-bd1a6ff18933/scratchpad"
pd <- file.path(SCR, "batchproj"); unlink(pd, recursive = TRUE)
proj <- se_project_create(pd, "bt", actor = "test")
# a table with a free-text NRIC and two same-subject dates
csv <- file.path(SCR, "bt_in.csv")
data.table::fwrite(data.frame(
  subj = c("P1","P1"), notes = c("NRIC S1234567D","clean"),
  visit = c("2020-01-01","2020-01-31"), stringsAsFactors = FALSE), csv)
proj$policy <- list(
  columns = list(
    subj  = list(identifier = "mrn", action = "pseudonymize", options = list()),
    notes = list(identifier = NA,    action = "redact_freetext", options = list()),
    visit = list(identifier = "dob", action = "generalize", options = list())),
  freetext_columns = "notes")
proj <- se_project_save(proj)
plan <- se_batch_plan(csv)
opts <- list(out_format = "csv",
             freetext_opts = list(use_pf = FALSE, min_conf = 0.5, types = NULL, rejects = character(0)),
             date_shift = TRUE, shift_window = 365L, shift_subject_col = "subj")
res <- se_batch_run(proj, plan, opts)
out <- data.table::fread(file.path(se_project_paths(pd)$outputs,
                                   res$items$output[res$items$type == "table"][1]))
stopifnot(grepl("\\[NRIC\\]", out$notes[1]))                 # NRIC redacted
d <- as.Date(out$visit)
stopifnot(all(!is.na(d)), as.integer(d[2] - d[1]) == 30L)    # interval preserved
stopifnot(!identical(as.character(d[1]), "2020-01-01"))      # actually shifted
cat("OK batch flags\n")
```

Run: `& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" "$SCRATCH\test_batch_flags.R"`
Expected: `OK batch flags`

- [ ] **Step 4: Commit**

```bash
git add app/R/batch.R app/batch_cli.R
git commit -m "$(printf 'batch: --pf/--ft-min-conf/--date-shift flags\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 10: Packaging — bundle PF, drop llama, prune spaCy

**Files:**
- Modify: `tools/build_bundle.ps1` (+ read `tools/stage_r.ps1`, `tools/check_closure.ps1`, `tools/audit_pathlen.ps1` to match conventions)

- [ ] **Step 1: Add onnxruntime + tokenizers to the bundled Python** — read how `bin/python` is currently staged (which script installs site-packages). Add `onnxruntime` and `tokenizers` to that install step. Verify no torch/transformers are pulled (they are NOT needed — we run the exported ONNX graph). Ensure the transitive closure is captured (numpy, protobuf, flatbuffers, etc. for onnxruntime) — this is the AndyFishing/SQLite lesson: a missing transitive dep fails import on the target.

- [ ] **Step 2: Ship `models/pf/`** — copy the Task 0 model dir (`model_fp16.onnx` [+ any `.onnx_data`], `tokenizer.json`, `config.json`) into the staged bundle at `models/pf/`. Add a `-PFModelDir` param (default the scratch `pf` dir) to `build_bundle.ps1`.

- [ ] **Step 3: Change the default include/exclude set** — in `build_bundle.ps1`:
  - **Exclude by default:** `bin/llama/` and `models/llm/*.gguf` (ends the AV-quarantine problem). Keep the existing `-IncludeLlama` / `-IncludeModels` switches to add them back.
  - **Prune by default:** the `en_core_web_lg` spaCy model directory from `bin/python` (large). Add `-SlimNER` (default `$true`); `-SlimNER:$false` keeps it. Keep the `presidio_analyzer`/`spacy` libraries (small) so the optional NER path still imports and the probe reports NER unavailable gracefully when the model is absent.
  - **Include by default:** `models/pf/` and the onnx/tokenizers site-packages.

- [ ] **Step 4: Rebuild the slim bundle to a short path** (avoid MAX_PATH in the worktree): build to `C:\sds_build`. Run `build_bundle.ps1` with defaults. Then run `tools/audit_pathlen.ps1` and `tools/check_closure.ps1` against the staged tree.
Expected: audit PASS (worst-case path < 260), closure PASS (no unresolved imports incl. onnxruntime/tokenizers).

- [ ] **Step 5: Verify on a real extraction** — extract the produced zip under the user profile (NOT `C:\sds_build`, where AV quarantines unsigned exes) e.g. `C:\Users\lauye\Downloads\sds_pf`, using Explorer "Extract All" or the .NET one-liner (NOT `tar.exe` — bsdtar misreads .NET Zip64). Then, from the extraction, run a PF end-to-end smoke:

Write `$SCRATCH/verify_pf_bundle.R` (point `se.pf_dir`/`se.python` at the extraction) that calls `se_py_probe()` (asserts `$pf` TRUE) and `se_pf_scan("Call John Tan at john@x.com")` (asserts a name + email row). Run with the extraction's own `bin\R` Rscript. Expected: probe `$pf==TRUE`; scan returns PF rows — proving offline ONNX inference works from a clean extraction with zero network.

- [ ] **Step 6: Commit**

```bash
git add tools/build_bundle.ps1
git commit -m "$(printf 'packaging: default bundle ships Privacy Filter, drops llama + spaCy model\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 11: Docs + final end-to-end verification

**Files:**
- Modify: `docs/packaging.md`, `CLAUDE.md`, `docs/roadmap.md`

- [ ] **Step 1: `docs/packaging.md`** — document the new default: PF included and on by default; `onnxruntime`+`tokenizers` in `bin/python`; `models/pf/` (Apache-2.0 provenance, `openai/privacy-filter`, exported ONNX); the offline fetch recipe (Task 0, curl/Schannel); `-IncludeLlama`/`-IncludeModels`/`-SlimNER`/`-PFModelDir` switches; note that PF fp16 CPU is the default and `model_q4f16.onnx` is the fallback if latency is poor on the target.

- [ ] **Step 2: `CLAUDE.md`** — update the "Design constraints" detection description: Privacy Filter (ONNX, out-of-process, socket-free) is the default free-text detector; MediPhi/Presidio are optional off-by-default backends; note the new `pf` runner mode disables sockets like `ner`. Update the "Detection engine" line and the `engine_py.R` / `deidentify.R` layout notes (`se_pf_scan`, `se_shift_date`, reviewable redaction).

- [ ] **Step 3: `docs/roadmap.md`** — add a short "Privacy Filter integration (2026-09-06)" entry: PF default detector via ONNX; interval-preserving `date_shift`; reviewable gated free-text redaction; slim AV-clean default bundle. Mark it done once verified.

- [ ] **Step 4: Full offline end-to-end on the synthetic sample** — from the clean extraction (Task 10 Step 5), launch the app, load `samples/`, run detection with PF on, confirm: rules catch NRIC/phone/dates; PF adds names in free text; select (reject) one finding and confirm it is NOT redacted in the output; set a date column to `date_shift` and confirm the output date differs but a two-date interval for the same subject is preserved; reviewer diff + approve works; crosswalk re-identifies both the pseudonyms and the shifted dates. **Run once with parallel workers > 1** (Detect free-text with `use_pf` on, then de-identify with parallelism) to confirm PF redaction works inside chunk workers — each worker spawns its own `bin/python` subprocess and must resolve `se_pf_config()` (bundle default path) and `se_py_binary()` from the worker's context; if a worker can't see the model, fix by exporting `SE_PF_DIR`/`SE_PYTHON` into the worker environment in `checkpoint.R`'s worker setup (mirror how `SE_SPACY_MODEL` is handled in `.se_py_run`). Capture a screenshot for the user.

- [ ] **Step 5: Commit**

```bash
git add docs/packaging.md CLAUDE.md docs/roadmap.md
git commit -m "$(printf 'docs: Privacy Filter default, date_shift, reviewable redaction\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Final review

After all tasks: dispatch a final code reviewer over the whole diff (all commits since the spec commit `8329064`), then use superpowers:finishing-a-development-branch. **Do not push** — ask the user first (standing rule).

## Verification summary (maps to spec "Verification")

- `_decode_bioes` unit test (Task 1) — headless, no model.
- `pf_scan` on the eval-style traps (Task 2) — name/email found, institution not over-redacted; ONNX fp16.
- Runner `pf` mode + `onnx` probe (Task 3).
- `se_pf_config`/`se_pf_scan` fail-closed + available (Task 4).
- Findings schema carries offsets; PF default (Task 5).
- `se_redact_freetext_spans` + reject gating (Task 6) — rejected span survives; accepted redacted; threshold + types honored.
- `se_shift_date` (Task 7) — same subject same offset, interval preserved, deterministic, key-sensitive, unparseable→`[DATE]`, crosswalk round-trip.
- testServer + browser (Task 8); batch flags (Task 9).
- Rebuilt slim bundle: `audit_pathlen` + `check_closure` PASS; offline PF smoke from a `Downloads` extraction (Task 10).
- Full offline end-to-end incl. over-redaction guard + date_shift + re-id (Task 11).
