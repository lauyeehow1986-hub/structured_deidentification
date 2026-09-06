# Offline NER (and optional LLM) packaging

The de-identification core runs with **zero Python**: deterministic rules,
validators (NRIC/FIN checksum, phone, email, dates) and column profiling all
work on the air-gapped box out of the box. This document is only needed to add
the **optional** free-text engines:

- **Offline NER** — Microsoft Presidio + spaCy `en_core_web_lg`, for names,
  locations and other entities buried in notes.
- **Optional local LLM** — a small local model for ambiguous free text, off by
  default. Preferred backend is a **socket-free bundled llama.cpp** (recommended
  model: **MediPhi-Instruct Q4_K_M**, the medical default; Qwen2.5-3B-Instruct
  Q4_K_M is the generalist fallback); a local Ollama is an alternative. See §2.

Both are bundled on an **internet-connected staging machine**, then copied to
the locked-down box. **The locked-down box never downloads anything** — the app
probes passively (file existence) at startup and only runs the bundled
interpreter when the operator clicks **Enable offline NER**.

### How R talks to Python (and why it's a subprocess)

The engine runs **out-of-process**: R (`app/R/engine_py.R`) invokes
`bin/python/python.exe app/python/run_engine.py <mode>` with a JSON request on
stdin and reads a JSON response from stdout. It does **not** embed Python in R
via reticulate. Two reasons:

- **Windows OpenSSL.** R's OpenSSL and a standalone Python's OpenSSL cannot
  safely share one process — embedding Presidio in-process crashes with
  `no OPENSSL_Applink`. A subprocess keeps the native libraries apart.
- **Air-gap.** The app never initialises Python in-process and never lets
  reticulate auto-provision from PyPI. For the `ner`/`probe` modes the runner
  additionally **hard-disables outbound sockets** (`_forbid_network()` in
  `run_engine.py`), so even a mis-behaving dependency cannot phone home. Only
  the opt-in `llm` mode is allowed a loopback socket to a local Ollama.

> **Air-gap finding, baked into the code.** Presidio's *predefined* recognizers
> include an `EmailRecognizer` that uses `tldextract`, which tries to **fetch the
> public-suffix list over the network** on first use. We therefore build the
> analyzer with a **spaCy-NER-only** recognizer registry (`detect_ner.py`): the
> deterministic R rules already catch email/phone/NRIC/etc., and this leaves
> Presidio doing pure local inference (names, locations, organisations, dates).

---

## Target layout in the bundle

Everything lives *inside* the unzip-and-run bundle so nothing resolves at
runtime:

```
<bundle>/
  bin/
    python/
      python.exe            # Windows portable/embeddable Python  (bin/python/python.exe)
      ...                   # or bin/python/bin/python3 on a portable *nix build
    llama/                  # optional local LLM (llama.cpp) — see §2
      llama.exe             # (or llama-cli.exe) + its ggml-*.dll / *.dll siblings
  app/
    python/
      detect_ner.py         # Presidio + spaCy contract (shipped)
      detect_llm.py         # llama.cpp + Ollama contract (shipped, optional)
  models/
    llm/                    # optional: a single *.gguf for the llama.cpp pass (§2)
```

`se_py_binary()` looks for `bin/python/python.exe` (Windows) or
`bin/python/bin/python3`; override with `options(se.python = "…")` or the
`SE_PYTHON` environment variable if you stage Python elsewhere.

---

## 1. Build the Python environment (staging machine, online)

Use a **portable / standalone** Python so no system install is required on the
target — e.g. a [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
release, matched to the target OS/arch (Windows x64 here). Pick a version with
wheels for the whole stack — **3.12** is a safe choice; 3.14 was too new for the
spaCy/Presidio compiled wheels at time of writing. If you copy a uv-managed
standalone Python, delete its `Lib/EXTERNALLY-MANAGED` marker in the copy first,
or pip refuses to install (PEP 668).

Unpack it to `bin/python/`, then install the NER stack **into that interpreter**:

```bash
# from the staging machine, with the bundle's interpreter
bin/python/python.exe -m pip install --upgrade pip
bin/python/python.exe -m pip install presidio-analyzer spacy
bin/python/python.exe -m spacy download en_core_web_lg
```

`en_core_web_lg` is the default (see `detect_ner.py`): it is loaded **by name,
offline**, and gives materially better recall on names than the small model. To
bundle a lighter model on a tight box, install `en_core_web_md` (or `_sm`)
instead and point the app at it with `options(se.spacy_model = "en_core_web_md")`
(or the `SE_SPACY_MODEL` environment variable).

> **Fully offline staging?** If even the staging machine is air-gapped, fetch
> the wheels and the model wheel elsewhere and install from a local directory:
> `pip download presidio-analyzer spacy en_core_web_lg -d wheels/` on an online
> box, copy `wheels/`, then
> `bin/python/python.exe -m pip install --no-index --find-links wheels/ presidio-analyzer spacy en_core_web_lg`.

### Verify on the staging machine

```r
options(se.bundle_root = "<bundle>")           # or run from the bundle root
source("app/global.R")
se_py_probe()                                  # actively imports the bundled py
se_py_status_text()                            # "Presidio + spaCy ready."
se_py_scan(c("Patient John Tan called from 91234567."))
```

You should get a `name` span for "John Tan" (and the rules already catch the
phone). Then zip the whole bundle and sneakernet it to the locked-down box.

---

## 2. Optional: bundle a local LLM

Only do this if the reviewers want an LLM second opinion on messy free text.
There are two backends; **llama.cpp is recommended for the air-gap** because it
opens **no socket at all** — it runs the same out-of-process, network-disabled
way as the NER pass. Ollama remains supported as an alternative. The app
auto-detects a bundled llama.cpp first, then a configured Ollama; force the
choice with `options(se.llm_backend = "llamacpp" | "ollama")` /
`SE_LLM_BACKEND`.

### 2a. llama.cpp (recommended, socket-free) — "just copy it in"

Two files make it work, both **auto-discovered** by file existence — no config:

1. **The binary** → `<bundle>/bin/llama/`. Download a llama.cpp **Windows CPU**
   release (`llama-<build>-bin-win-cpu-x64.zip`) from
   <https://github.com/ggml-org/llama.cpp/releases> and unzip **all** of it
   (the `.exe` needs its sibling `ggml-*.dll` / `*.dll`) into `bin/llama/`.
   Recent builds ship a unified `llama.exe` (invoked as `llama.exe cli …`);
   older ones ship `llama-cli.exe`. Either is picked up.
2. **The model** → `<bundle>/models/llm/<one>.gguf`. Drop a single GGUF in that
   folder; if exactly one is present it is used automatically.

   **Recommended (medical default): MediPhi-Instruct, Q4_K_M** (~2.4 GB, **MIT**
   — clean for redistribution). MediPhi is a Phi-3.5-mini SLM tuned by Microsoft
   for clinical **information extraction / NER** — the same shape as PII
   span-tagging — so it is the strongest of the small models at the one thing the
   LLM pass actually adds over the deterministic rules: **names buried in free
   text**. On the staging machine:

   ```bash
   curl -L -o models/llm/mediphi-instruct-q4_k_m.gguf \
     https://huggingface.co/mradermacher/MediPhi-Instruct-GGUF/resolve/main/MediPhi-Instruct.Q4_K_M.gguf
   ```

   **Generalist fallback: Qwen2.5-3B-Instruct, Q4_K_M** (~2.1 GB, **Apache-2.0**,
   strong JSON adherence, slightly faster). Keep it as the license-clean
   general-purpose option — or if a deployment cannot use the medical model for
   any reason:

   ```bash
   curl -L -o models/llm/qwen2.5-3b-instruct-q4_k_m.gguf \
     https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf
   ```

   Keep total RAM in mind: 16 GB is shared with Windows + R + the resident spaCy
   model, so a 3B/3.8B **Q4** is the safe ceiling. **If you bundle several GGUFs**
   the preference order is `mediphi*` → `qwen2.5-3b*` → `qwen*`; otherwise point
   the app at one explicitly with `options(se.llamacpp_model = "…")` /
   `SE_LLAMACPP_MODEL`.

   > **Why MediPhi is the default — the A/B.** Both models were run in isolation
   > (LLM pass only, no rules/NER) over a synthetic gold set of 20 clinical-style
   > free-text notes (30 planted PII spans across names/phone/NRIC/email/date/
   > address/postal + 4 negative-control notes), scored by span-overlap:
   >
   > | model | recall | precision | span-F1 | name recall | FP on negatives |
   > |---|---|---|---|---|---|
   > | **MediPhi-Instruct** | **0.80** | 1.00 | **0.889** | **0.71** | 0 |
   > | Qwen2.5-3B | 0.77 | 1.00 | 0.868 | 0.57 | 0 |
   >
   > Both have **perfect precision and zero over-flagging** on the negative
   > controls — essential for a governance tool. The overall margin is one span,
   > but the *shape* of the difference is what decides it: MediPhi is materially
   > better at **names** (0.71 vs 0.57), which is exactly the LLM's job here, while
   > Qwen's only wins were on NRIC/FIN and email — identifiers the deterministic
   > rules (`detect_r.R`) already catch with 100% reliability, so MediPhi's
   > weaknesses are fully covered in production. Qwen is ~40 % faster and stays the
   > bundled generalist fallback.

   > **Output-format note (baked into the code).** Small models format JSON
   > differently: Qwen emits compact one-liners, **MediPhi pretty-prints**
   > (newlines + indentation), which inflates the token count of a batch's reply.
   > The reply parser (`_parse_spans` in `detect_llm.py`) therefore **salvages
   > every complete `{…}` span object** rather than requiring one well-formed
   > `[…]` array — so it is robust to pretty-printing, to a completion truncated at
   > `n_predict` (it keeps the objects generated before the cut instead of
   > returning nothing), and to the prompt echo. The shipped default
   > `se.llm_n_predict` is **1024** (not 512) to give a pretty-printing model room
   > to finish a batch. A headless regression test for the parser runs with no
   > model or binary needed: `bin/python/python.exe app/python/detect_llm.py`.

That's it — copy the whole bundle to the locked-down box and it runs. Override
paths only if you stage them elsewhere: `options(se.llamacpp_bin = "…")` /
`SE_LLAMACPP_BIN`. Tuning knobs (with defaults): `se.llm_batch` (16 cells per
model load), `se.llm_ctx` (4096), `se.llm_n_predict` (1024 — headroom for a
pretty-printing model; see the output-format note in §2a).

> **Antivirus may quarantine the binary — mainly on the staging box.** A freshly
> downloaded, unsigned `llama*.exe` is often silently deleted by AV (AVG / McAfee
> seen doing this on the staging box). **Add `bin/llama/` to the AV exclusions on
> the staging machine** (or unblock the extracted files) before you build the
> bundle, or llama.cpp vanishes mid-run and the pass falls back to rules+NER. The
> GGUF (data) is not flagged. Once the bundle is sneakernetted to a locked-down
> box that does **not** run AVG/McAfee, this does not recur; if the target does
> run such AV, exclude `bin/llama/` there too.

> **Verify on the staging machine:**
> ```r
> options(se.bundle_root = "<bundle>"); source("app/global.R")
> se_llm_config()$backend        # "llamacpp"
> se_py_probe()$llm              # TRUE
> se_llm_scan(c("Patient John Tan called 91234567"))   # name + phone spans
> ```

> **Performance.** The CLI reloads the model **once per batch** of `se.llm_batch`
> cells (no persistent server = no socket). Warm, a 3B-Q4 batch is a few seconds
> on CPU; the *first* load can take a minute or two while AV scans the DLLs and
> the 2 GB model is paged in. It is an opt-in second-opinion pass over free-text
> columns — not a bulk detector — so this is acceptable; keep columns free-text
> and let rules+NER carry the load.

### 2b. Ollama (alternative, loopback socket)

1. Install [Ollama](https://ollama.com) on the staging machine and pull a small
   instruct model, e.g. `ollama pull qwen2.5:3b` (or `llama3.2`).
2. Copy the Ollama binary and its model store to the bundle (default model store
   is `~/.ollama/models`; relocate with `OLLAMA_MODELS`). Run a local, bundled
   Ollama that listens on loopback only.
3. Add the Python client to the bundled interpreter so `detect_llm.py` can reach
   it: `bin/python/python.exe -m pip install ollama` (or `requests`).
4. Configure the app:

   ```r
   options(se.llm_backend = "ollama",
           se.ollama_model = "qwen2.5:3b",
           se.ollama_url   = "http://127.0.0.1:11434")   # loopback only
   ```

   (or set `SE_LLM_BACKEND` / `SE_OLLAMA_MODEL` / `SE_OLLAMA_URL`).

In the app, tick **Use a local LLM (llama.cpp / Ollama) for ambiguous free
text** on the Detect tab. LLM findings appear in the free-text table tagged
`llm:llamacpp` or `llm:ollama` with a modest confidence — treat them as hints
for a human, never as ground truth.

> **Air-gap caveat (Ollama only).** The Ollama backend is the *only* part of the
> whole system that opens a socket, and it opens it to a **local** Ollama on
> `127.0.0.1` that you chose to bundle and run — no remote endpoint, no fallback.
> The llama.cpp backend opens none (the `llm` runner mode disables outbound
> sockets for every backend except `ollama`). If your deployment forbids any
> socket at all, use llama.cpp (or leave the LLM off entirely; NER + rules need
> no network). For Ollama, confirm it is bound to loopback and that host firewall
> rules block egress.

---

## Behaviour when the engines are absent

- No bundled interpreter → **Enable offline NER** reports "rules-only mode" and
  the NER/LLM checkboxes are inert (the engines fail closed to empty).
- Interpreter present but Presidio/spaCy missing → same rules-only fallback,
  with a status line saying the model is missing.
- Nothing is ever fetched, initialised, or provisioned without an explicit
  operator click, and even then only the on-disk bundled interpreter is used.
