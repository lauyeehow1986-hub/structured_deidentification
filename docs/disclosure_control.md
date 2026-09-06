# Statistical disclosure control — measures + risk-reduction transforms (Phase 5)

The **Disclosure control** tab is entirely **opt-in**: nothing here changes your
output unless you run it. It has two halves — **measures** that quantify
re-identification risk, and **transforms** that reduce it — plus a hard
**export gate**. Everything is pure R (`app/R/sdc.R` metrics,
`app/R/sdc_transforms.R` transforms); no network, no external binary.

## The working table (and why it may be a sample)

Measures and transforms operate on a **bounded, representative sample** of the
current de-identified output (or the loaded input when nothing has been
de-identified yet), capped at `se.sdc_sample_cap` (default 20,000 rows). This
keeps a huge output from being loaded whole. When sampling is in effect the tab
says so and treats risk numbers — and the gate — as **estimates**. Both halves
draw the *same* sample, so a treated row stays aligned with its original row for
DCR linkage risk.

## Measures (`app/R/sdc.R`)

| Measure | Function | Reports |
|---|---|---|
| k-anonymity | `se_kanon` | smallest quasi-group (k achieved), records below target k, uniques |
| l-diversity | `se_ldiversity` | min distinct sensitive values per quasi group |
| Sample uniques (SUDA-lite) | `se_sample_uniques` | % unique on the full quasi set and worst (k−1)-subset |
| Individual risk | `se_individual_risk` | mean / max re-identification risk + expected re-ids (sdcMicro) |
| Linkage risk (DCR) | `se_dcr` | distance-to-closest-record vs the original; % exact matches |

The **export gate** (`se_sdc_gate`) blocks when k is below target or max
individual risk exceeds the threshold, and lists the reasons.

## Risk-reduction transforms (`app/R/sdc_transforms.R`)

Each transform has the same contract — `list(data, note, n_changed, op)` — and
reduces disclosure risk at a stated cost to utility. Randomised transforms take a
`seed` so a treatment is reproducible and auditable (as sdcMicro does).

| Transform | Function | What it does |
|---|---|---|
| Local suppression | `se_sdc_suppress` | Blank (NA) the quasi cells of every record in a group smaller than k — the classic step that *forces* k-anonymity. Optionally restrict to chosen columns. |
| Global recode / banding | `se_sdc_recode` | Coarsen one column: numeric → bands (`breaks` + optional `labels`); categorical → `mapping` (old→new; unlisted levels kept). |
| Top / bottom coding | `se_sdc_topbottom` | Cap extreme, uniquely-identifying numeric values at a percentile (`top_pct`/`bottom_pct`) or absolute cut (`top`/`bottom`). |
| Microaggregation | `se_sdc_microaggregate` | Individual-ranking: sort a numeric column, form consecutive groups of size `aggr`, replace each by the group mean/median. Every released value is then shared by ≥ `aggr` records; a short final group is merged so no record is left singleton; integer columns are rounded back. |
| PRAM | `se_sdc_pram` | Post-randomisation on a categorical column: keep each value with probability `retain`, else redraw from the column's own marginal — deniability while preserving the distribution in expectation. |
| Noise addition | `se_sdc_noise` | Additive noise on numeric columns. `gaussian`: N(0, (pct·SD)²). `laplace`: Laplace noise; with `epsilon` the column is clamped to `[lower, upper]` and the scale is `(upper−lower)/epsilon` — a DP-style calibrated mechanism. |
| Synthetic replacement | `se_sdc_synth_marginal` / `se_sdc_synth_flexsynth` | Replace quasi columns with fresh draws. Marginal resynthesis (pure R) breaks the joint quasi combination so no released row matches a real person's profile; when the author's **flexsynth** package is installed, joint-preserving synthesis is used instead (falls back to marginal, with a note, when absent). |

`se_sdc_apply(df, steps)` threads a data.frame through a list of
`list(op, args)` specs — used to reproduce a recorded treatment and to drive the
tab.

## The Preview → Apply → measure loop

1. **Pick** a transform and its parameters (the parameter panel changes per
   transform).
2. **Preview effect** — applies it to the working table *without committing* and
   shows k-anonymity **before vs after** (given the selected quasi columns). Nothing
   is saved.
3. **Apply to treated table** — commits the transform onto a treated copy and
   stacks it on top of any earlier ones; the running treatment is listed.
4. **Run selected measures** — now evaluates the **treated** table, so you can
   confirm k rose / uniques fell and the **export gate** turns to PASS.
5. **Download treated table** — writes the treated CSV. **Reset treatments**
   clears the stack and returns to the untreated working table.

When a project is open, `sdc_transform`, `sdc_run`, and `sdc_export_treated`
actions are recorded in the tamper-evident audit trail.

## A note on differential privacy

The Laplace/`epsilon` noise option is a **per-value Laplace mechanism** — a
strong, calibrated perturbation. Formal (ε)-differential privacy for a *released
microdata table* additionally requires bounding each individual's contribution
across the whole release; this tool offers the mechanism as an SDC transform, not
as a table-level DP guarantee. For DP release of *aggregate statistics*, use a
dedicated DP accounting workflow. The data controller remains responsible for
confirming adequacy of de-identification before release.

## Tests

Headless self-tests cover every transform (correct effect, reproducibility by
seed, row-count preservation, integer rounding, the microaggregation group-size
guarantee, and that a stacked treatment drives the gate to PASS), and a
`testServer` suite covers the Preview/Apply/Reset/measure-on-treated wiring and
input validation.
