# Offline NER (and optional LLM) packaging

The de-identification core runs with **zero Python**: deterministic rules,
validators (NRIC/FIN checksum, phone, email, dates) and column profiling all
work on the air-gapped box out of the box. This document is only needed to add
the **optional** free-text engines:

- **Offline NER** — Microsoft Presidio + spaCy `en_core_web_lg`, for names,
  locations and other entities buried in notes.
- **Optional local LLM** — an Ollama model for ambiguous free text. Off by
  default; see the warning at the end.

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
  app/
    python/
      detect_ner.py         # Presidio + spaCy contract (shipped)
      detect_llm.py         # Ollama contract (shipped, optional)
  models/                   # optional extra model store (Ollama)
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

## 2. Optional: bundle a local LLM (Ollama)

Only do this if the reviewers want an LLM second opinion on messy free text.

1. Install [Ollama](https://ollama.com) on the staging machine and pull a small
   instruct model, e.g. `ollama pull llama3.2`.
2. Copy the Ollama binary and its model store to the bundle (default model store
   is `~/.ollama/models`; relocate with `OLLAMA_MODELS`). Point the bundle's
   launcher at a local, bundled Ollama that listens on loopback only.
3. Add the Python client to the bundled interpreter so `detect_llm.py` can reach
   it: `bin/python/python.exe -m pip install ollama` (or `requests`).
4. Configure the app:

   ```r
   options(se.ollama_model = "llama3.2",
           se.ollama_url   = "http://127.0.0.1:11434")   # loopback only
   ```

   (or set `SE_OLLAMA_MODEL` / `SE_OLLAMA_URL`).

In the app, tick **Use a local LLM (Ollama) for ambiguous free text** on the
Detect tab. LLM findings appear in the free-text table tagged `llm:ollama` with
a modest confidence — treat them as hints for a human, never as ground truth.

> **Air-gap caveat.** The LLM pass is the *only* part of the whole system that
> opens a socket, and it opens it to a **local** Ollama on `127.0.0.1` that you
> chose to bundle and run — no remote endpoint, no fallback. If your deployment
> forbids any socket at all, leave it off; NER + rules need none. Confirm your
> Ollama is bound to loopback and that host firewall rules block egress.

---

## Behaviour when the engines are absent

- No bundled interpreter → **Enable offline NER** reports "rules-only mode" and
  the NER/LLM checkboxes are inert (the engines fail closed to empty).
- Interpreter present but Presidio/spaCy missing → same rules-only fallback,
  with a status line saying the model is missing.
- Nothing is ever fetched, initialised, or provisioned without an explicit
  operator click, and even then only the on-disk bundled interpreter is used.
