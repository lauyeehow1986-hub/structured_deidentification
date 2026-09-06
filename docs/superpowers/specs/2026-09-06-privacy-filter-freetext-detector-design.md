# Privacy Filter free-text detector — design

**Date:** 2026-09-06
**Status:** approved (design)
**Author:** YH + Claude

## Context

The structured de-identification tool detects PII in three layers: deterministic
rules/validators (`detect_r.R`, always on), an optional offline NER pass
(Presidio + spaCy, `se_py_scan`), and an optional local-LLM pass (MediPhi/Qwen via
llama.cpp, `se_llm_scan`). Both optional passes are **off by default**.

An A/B test on a 25-text / 45-entity synthetic clinical free-text set (offline,
CPU) compared **OpenAI Privacy Filter** (`openai/privacy-filter`, Apache-2.0,
open-weight token classifier) against the shipped MediPhi path and the Presidio
baseline:

| Method | Detect P/R/F1 | Over-redaction (FP) | Latency (25 texts) |
|---|---|---|---|
| OpenAI Privacy Filter | 1.00 / 0.87 / 0.93 | 0 | 3.2 s load + 11.9 s |
| MediPhi (llama.cpp, shipped default) | 0.00 / 0.00 / 0.00 | 0 | 66 s |
| MediPhi (batch 1) | 0.00 / 0.00 / 0.00 | 0 | 2901 s (~6 min/text) |
| Presidio + spaCy | 0.68 / 0.56 / 0.61 | 12 | 5 s |

Privacy Filter won decisively: highest recall, **perfect precision / zero
over-redaction** (it left institutions like "Singapore General Hospital" and
clinical numbers alone), ~25–240× faster than MediPhi, and clean token-span
output with none of the JSON-parse fragility that makes MediPhi emit
per-character garbage. It is a bidirectional token classifier (BIOES + span
decoding), 1.5B params / 50M active, 128k context, and runs fully locally.

**Decision:** make Privacy Filter the default free-text detector, running
out-of-process via ONNX Runtime, and slim the bundle by dropping the llama.cpp
LLM (and the spaCy NER model) from the default. Deterministic rules stay primary
for the Singapore-specific identifiers PF has no native category for.

## Goals

- A new offline, air-gapped free-text PII detector backed by Privacy Filter,
  **on by default**, reproducing ~0.93 detection F1 on the eval set.
- Fits the existing out-of-process pattern (JSON in/out via `run_engine.py`),
  no torch/transformers at runtime — only `onnxruntime` + `tokenizers`.
- A smaller, AV-clean default bundle (no unsigned `bin/llama` exes).
- Deterministic rules remain primary for NRIC/FIN/MRN/phone/email/postal.
- MediPhi and Presidio code paths retained as optional, off-by-default backends.

## Non-goals

- Fine-tuning Privacy Filter to add SG-specific labels (NRIC/FIN/MRN). Rules own
  those; fine-tuning is a possible later enhancement.
- Changing the identifier catalogue, transform engine, crypto, audit, or SDC.
- GPU inference. CPU only, consistent with the locked-down target.

## Architecture

New out-of-process detector, mirroring `se_py_scan` (NER):

```
R  se_pf_scan(texts)
   -> .se_py_run("pf", {texts})
   -> bundle/bin/python/python.exe app/python/run_engine.py pf   (stdin JSON)
   -> detect_pf.py: onnxruntime InferenceSession + tokenizers.Tokenizer
        - tokenize with offset mapping
        - one forward pass -> per-token logits -> argmax label ids
        - decode BIOES spans (merge consecutive same-base-type tokens),
          gated by viterbi_calibration.json thresholds
        - map PF labels -> our identifier ids
   -> stdout JSON: [ {row,start,end,match,type,identifier,detector,confidence}, ... ]
```

Network is hard-disabled for the `pf` mode (added to `_forbid_network` in
`run_engine.py`), so it opens zero sockets — the same air-gap guarantee as NER.

### Detection flow

`se_detect_freetext(df, ftcols, use_pf = TRUE, use_ner = FALSE, use_llm = FALSE,
detectors)`:

1. Deterministic rules per cell (always) — unchanged, primary.
2. If `use_pf` (default TRUE): `se_pf_scan(vals)` per free-text column.
3. If `use_ner` (default FALSE): `se_py_scan` (legacy Presidio path).
4. If `use_llm` (default FALSE): `se_llm_scan` (legacy MediPhi/Ollama path).

Findings merge through the existing `se_dedup_findings`, which keeps the
highest-confidence detector per `(row, column, match, type)`. Confidence tiers:
validated rules ~0.90–0.99 (NRIC/FIN checksum highest), **PF 0.85**, NER/LLM
lower. So rules stay authoritative on overlaps; PF adds names/addresses/dates and
context-dependent PII the rules miss.

## Label map (PF -> identifier id / type)

| PF label | identifier id | type |
|---|---|---|
| private_person | name | name |
| private_address | address | address |
| private_email | email | email |
| private_phone | phone | phone |
| private_date | dob | date |
| private_url | other_id | url |
| account_number | other_id | account |
| secret | other_id | secret |

NRIC/FIN/MRN/postal are **not** PF categories; the deterministic rules detect
them. PF may tag an NRIC as `account_number` → `other_id`; harmless (still
flagged/redacted, and the rule's `national_id` finding wins the dedup on the same
span by higher confidence).

## Components

### `app/python/detect_pf.py` (new)

- `pf_scan(texts, model_dir) -> list[span dict]` — the public entry called by
  `run_engine.py`.
- Internals: load `onnxruntime.InferenceSession(model_fp16.onnx)` once;
  `tokenizers.Tokenizer.from_file(tokenizer.json)`; read `config.json` id2label
  and `viterbi_calibration.json`; encode each text with offsets; run; argmax;
  `_decode_bioes(ids, offsets, id2label)` merges consecutive same-base-type
  tokens into `(base, start, end)`; map to identifier id; emit span dicts with
  1-based `row`/`start` to match the R schema, `detector="pf"`, `confidence=0.85`.
- `_decode_bioes` is a pure function, unit-tested on synthetic logits (no model).
- Fail-closed: any exception (missing model/lib) → return `[]`.

### `app/python/run_engine.py` (modify)

- Add `pf` to the network-forbidden set.
- Add `elif mode == "pf": import detect_pf; result = detect_pf.pf_scan(
  req.get("texts", []), req.get("model_dir", ""))`.

### `app/R/engine_py.R` (modify)

- `se_pf_config()` — discover `<bundle>/models/pf/` (model + tokenizer) via
  `getOption("se.pf_dir")` / `SE_PF_DIR` else the bundle path; file-existence only.
- `se_pf_scan(texts)` — build payload `{texts, model_dir}`, `.se_py_run("pf", ...)`,
  return the span df or `.se_empty_ner()`.
- Extend `se_py_probe()` to set `st$pf` (python present + model files exist).
- `se_detect_freetext(...)` — add `use_pf = TRUE` param; call `se_pf_scan` as
  step 2 above; flip `use_ner`/`use_llm` defaults to FALSE.
- Callers of `se_detect_freetext` (app.R server, batch.R) pass `use_pf` from the
  UI/CLI; default TRUE.

### `app/app.R` (modify)

- Detection tab: primary checkbox **"Enable Privacy Filter (free-text PII)"**
  (default checked), driven by `se_py_probe()$pf`. NER and LLM become secondary
  "advanced / optional backend" toggles (default off), with a note they require
  the separately-bundled models.
- `batch.R` / `batch_cli.R`: `--pf` on by default, `--no-pf` to disable; keep the
  existing NER/LLM opts.

### Packaging (modify)

- Bundled python gains `onnxruntime` + `tokenizers` (installed into `bin/python`;
  transitive closure checked by `check_closure.ps1`).
- Ship `models/pf/` = `model_fp16.onnx` (+ `.onnx_data*`), `tokenizer.json`,
  `config.json`, `viterbi_calibration.json`.
- `build_bundle.ps1` defaults change: **include** `models/pf/`; **exclude**
  `bin/llama`, GGUF models, and prune the `en_core_web_lg` spaCy model from
  `bin/python` (keep `presidio_analyzer`/`spacy` libs — small — so the optional
  NER path still works if a model is added back). New switches:
  `-IncludeLlama`/`-IncludeModels` still add the legacy LLM; a `-SlimNER` (default
  on) prunes the spaCy model.
- `docs/packaging.md` + `CLAUDE.md`: document the new default (PF on, llama/spaCy
  optional), the model provenance (Apache-2.0), and the offline download recipe.

## Air-gap, AV, MAX_PATH

- **Air-gap:** `pf` mode disables sockets; onnxruntime does no network; model is
  local. No runtime downloads, ever.
- **AV:** onnxruntime DLLs are signed/common; dropping unsigned `bin/llama/*.exe`
  from the default **ends the AV-quarantine problem** that plagued the LLM bundle.
- **MAX_PATH:** `models/pf/` uses short names; onnxruntime site-packages paths are
  moderate; the existing `audit_pathlen.ps1` gate fails the build if anything
  exceeds budget.

## Verification

- `detect_pf.py` decoder unit test on synthetic BIOES logits (headless; no model).
- End-to-end: `se_pf_scan` over the A/B eval set reproduces ~0.93 detection F1 and
  0 false positives (institution/clinical-number traps); ONNX fp16 result stays
  within a small tolerance of the transformers fp16 run.
- Rebuilt slim bundle: `audit_pathlen` + `check_closure` PASS; `verify_clean_machine`
  PASS; a new PF smoke (load model, scan a sentence, assert PERSON/EMAIL spans),
  offline, from a `Downloads` extraction.
- `testServer` for the Detection tab PF toggle.
- Ad-hoc self-tests live in the scratchpad; the repo commits no tests.

## Risks / open items

- **ONNX fp16 on CPU** upcasts internally; if latency is poor on the target, fall
  back to `model_q4f16.onnx` (validate accuracy first). fp16 chosen for fidelity.
- **onnxruntime wheel size / closure** must be transitively bundled or the target
  fails to import — same lesson as the SQLite/AndyFishing bundle.
- **Custom PF arch at runtime:** we do NOT use transformers at runtime; we run the
  exported ONNX graph directly, so the `openai_privacy_filter` arch support in
  transformers is only needed at export time (OpenAI already exported the ONNX in
  the repo — we ship theirs, no re-export needed).
- **spaCy-model prune** must not break `presidio`/`spacy` imports (probe should
  report NER unavailable gracefully when the model is absent).
