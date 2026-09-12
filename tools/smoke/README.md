# Headless smoke suite

Pure-R functional smoke tests over the whole core (`app/R/*.R`), driven by the
synthetic fixtures in `samples/` (no real data, no network). They assert real
behaviour — de-identification, re-identification, disclosure control, document
scrubbing, the checkpointed pipeline, and the Privacy Filter — and print a
per-check `PASS`/`FAIL` table. Each suite exits non-zero if anything fails, so
they double as a regression gate.

## Run

From the **repo root** (bundled or dev R both work):

```
& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" tools/smoke/run_all.R
```

Or run one suite at a time:

```
& "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" tools/smoke/smoke1_core.R
```

Regenerate the fixtures first if `samples/` is empty:

```
Rscript samples/make_sample.R
Rscript samples/make_xml_samples.R
```

## What each suite covers

| Script | Coverage |
|---|---|
| `smoke1_core.R` | crypto (keyed pseudonyms, FPE round-trip + fallback, AEAD crosswalk/blob, ed25519 sign/verify), detectors + validators (NRIC/Luhn/email/phone/date/postal, watchlist, `extra=` hook), profiling + misplaced-PII, every de-identify transform, interval-preserving date-shift, and the tamper-evident audit chain |
| `smoke2_sdc_docs.R` | SDC metrics (k-anon, l-diversity, SUDA-lite, individual risk, DCR) + export gate; all risk-reduction transforms + `sdc_apply`; XML/ECG scrub across all 5 profiles (PHI removed, waveform preserved); PDF true redaction with re-OCR verification |
| `smoke3_pipeline.R` | project lifecycle, register + SHA-256 manifest, checkpointed de-id with resume (rerun + mid-job) and parallel workers, crosswalk persistence + authorized re-id, certificate + pure-R PDF report, signed handoff, and the batch runner (CSV + XML routing) |
| `smoke4_pf.R` | the **default** free-text detector — the Privacy Filter (ONNX, out-of-process). The PF model is not in the repo (it ships in the bundle); this suite auto-discovers it (`SE_PF_DIR`, a built bundle, or `./models/pf`) and **skips cleanly** if absent |

## Environment overrides

- `SDS_SMOKE_DIR` — scratch dir for `smoke3` projects/checkpoints (default: a temp dir).
- `SE_PF_DIR` — directory holding the Privacy Filter `*.onnx` + `tokenizer.json` + `config.json` for `smoke4`.
