"""detect_llm.py — OPTIONAL local-LLM pass for ambiguous free text.

Two backends, both LOCAL and both opt-in; called from R (engine_py.R ->
se_llm_scan) out-of-process via run_engine.py, and only when the operator has
explicitly enabled the LLM pass. The pass asks a small local model to flag spans
of personal data that the deterministic rules and NER may miss in messy free
text, and returns them in the shared findings-span schema so they merge with the
other detectors.

  * "llamacpp" (RECOMMENDED for air-gap) — runs the bundled `llama-cli` binary as
    a one-shot subprocess against a bundled GGUF model. **No socket at all**: it
    fits the same out-of-process pattern as the NER pass, so the whole system
    opens zero network connections. Just drop the binary + model into the bundle
    (see docs/ner_packaging.md) and it is auto-discovered.
  * "ollama" — asks a LOCAL Ollama service (default http://127.0.0.1:11434). This
    is the ONE place in the whole system that opens a socket, and it is a loopback
    call to an Ollama the operator chose to bundle and run. No remote endpoint, no
    fallback.

If the chosen backend is unavailable (binary/model missing, client lib missing,
model unset, or the service unreachable), llm_scan returns an empty list and the
app carries on with rules (+NER) only. Findings are HINTS for a human reviewer
(modest confidence), never ground truth.
"""

from typing import List, Dict, Any
import json
import re

# Map coarse LLM labels to our identifier ids (see identifiers.R).
_LABEL_TO_IDENTIFIER = {
    "name": "name",
    "person": "name",
    "nric": "national_id",
    "fin": "national_id",
    "passport": "national_id",
    "national_id": "national_id",
    "mrn": "mrn",
    "phone": "phone",
    "fax": "fax",
    "email": "email",
    "address": "address",
    "postal": "postal_code",
    "date": "dob",
    "dob": "dob",
    "other": "other_id",
}

_TYPES = "name, nric, mrn, phone, fax, email, address, postal, date, other"

# Ollama prompt: one text in, offset spans out (0-based, end exclusive).
_SYSTEM = (
    "You are a strict PII detector for clinical free text. "
    "Given ONE input text, return ONLY a compact JSON array (no prose, no code "
    "fences) of objects {\"start\":int,\"end\":int,\"type\":str} for each span "
    "that is personal data. start/end are 0-based character offsets into the "
    "text, end exclusive. type is one of: " + _TYPES + ". "
    "If nothing is found, return []."
)

# llama.cpp prompt: a batch of texts in, verbatim-substring spans out. Asking for
# the exact substring (rather than offsets) is far more robust on small models —
# we locate it back in the source text ourselves to compute real offsets, and we
# do NOT trust the model's index `i` (small models often 1-base it); the verbatim
# text is matched across the batch instead. A worked example markedly lifts
# recall on a 3B model. No JSON-schema/grammar is used: in current llama.cpp the
# grammar sampler collides with the chat template's control tokens, so we rely on
# the prompt + strict parsing (fail-closed to [] if the reply isn't parseable).
_LLAMA_SYS = (
    "You are a strict PII detector for clinical free text. The user gives a JSON "
    "array `inputs` of strings. Find EVERY span of personal data: patient/staff "
    "names, phone/fax numbers, emails, addresses, postal codes, NRIC/FIN, MRN, "
    "dates of birth/death. Output ONLY a JSON array of objects "
    "{\"i\":int,\"text\":str,\"type\":str} (no prose, no code fences). \"text\" "
    "MUST be copied verbatim from the matching input string. \"type\" is one of: "
    + _TYPES + ". Output [] only if there is truly no personal data. "
    "Output COMPACT JSON on a single line with no extra whitespace, no newlines "
    "and no indentation. "
    "Example: inputs = [\"Call Mary Lee at 61234567\"] -> "
    "[{\"i\":0,\"text\":\"Mary Lee\",\"type\":\"name\"},"
    "{\"i\":0,\"text\":\"61234567\",\"type\":\"phone\"}]"
)

# Strip ANSI colour escapes that llama.cpp's console UI wraps output in.
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _parse_spans(content: str):
    """Salvage every complete span OBJECT ({...}) from the model reply.

    Rather than extract one big `[...]` array, we collect each balanced top-level
    JSON object that decodes to a dict carrying a span key ("text" for the
    llama.cpp contract, "start" for the Ollama one). This is deliberately robust
    to how small models actually format output:

      * **Pretty-printed vs compact.** MediPhi pretty-prints (newlines + indent),
        which inflates the token count; Qwen emits compact one-liners. Object
        scanning ignores whitespace entirely.
      * **Truncation.** If the completion is cut off at `n_predict` mid-array (no
        closing `]`), every object generated *before* the cut is still salvaged —
        the pass degrades to partial recall instead of silently returning zero
        (the earlier array-only parser fell back to the echoed input array and
        yielded nothing at large batch sizes).
      * **Echoed prompt / multiple arrays.** llama.cpp's conversation UI echoes
        `inputs = ["..."]` (bare strings — no objects) and wraps text in ANSI
        colour codes; both are ignored here. ANSI is stripped first.

    A tiny JSON string-state machine keeps braces that appear *inside* string
    values (e.g. a note containing "{") from throwing off brace depth. Spurious
    objects are self-cleaning downstream: the llama.cpp path keeps only spans
    whose "text" is a verbatim substring of an input, and the Ollama path only
    those whose offsets fall inside the text."""
    if not content:
        return []
    text = _ANSI.sub("", content)
    spans = []
    depth = 0
    start = -1
    in_str = False
    esc = False
    for idx, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = idx
            depth += 1
        elif ch == "}" and depth > 0:
            depth -= 1
            if depth == 0 and start >= 0:
                try:
                    obj = json.loads(text[start:idx + 1])
                    if isinstance(obj, dict) and ("text" in obj or "start" in obj):
                        spans.append(obj)
                except Exception:
                    pass
                start = -1
    return spans


# ---------------------------------------------------------------------------
# Backend: llama.cpp one-shot CLI (socket-free)
# ---------------------------------------------------------------------------

def _run_llama(llama_bin: str, model_path: str, system: str, user: str,
               n_predict: int, ctx: int, timeout: int = 600) -> str:
    """Invoke the bundled llama.cpp once, CPU-only, deterministic, single-turn.
    `-sys`/`-p` let llama apply the model's own chat template exactly once; `-st`
    runs one turn and exits (non-interactive). stdout carries a banner + the
    completion; the caller's parser extracts the JSON. stderr is discarded.
    Handles both the unified `llama(.exe) cli ...` dispatcher and a classic
    `llama-cli(.exe) ...`. Returns "" on any failure (fail-closed)."""
    import os
    import subprocess
    stem = os.path.splitext(os.path.basename(llama_bin))[0].lower()
    args = [llama_bin]
    if stem in ("llama", "llama-run"):        # unified dispatcher needs subcommand
        args.append("cli")
    args += [
        "-m", model_path,
        "-sys", system,
        "-p", user,
        "-st",                       # single turn, then exit (non-interactive)
        "--no-display-prompt",
        "--no-warmup",
        "-n", str(int(n_predict)),
        "--temp", "0",
        "-c", str(int(ctx)),
        "-ngl", "0",                 # CPU only (no GPU offload)
    ]
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception:
        return ""
    try:
        return p.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


def _scan_llamacpp(texts: List[str], model_path: str, llama_bin: str,
                   n_predict: int, ctx: int, batch: int) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    if not model_path or not llama_bin:
        return out
    # keep global row indices while dropping empty cells (a model load is costly)
    items = [(i, str(t)) for i, t in enumerate(texts) if t is not None and str(t)]
    if not items:
        return out
    if batch < 1:
        batch = 1
    for start in range(0, len(items), batch):
        chunk = items[start:start + batch]
        inputs = [t for _, t in chunk]
        user = "inputs = " + json.dumps(inputs, ensure_ascii=False)
        content = _run_llama(llama_bin, model_path, _LLAMA_SYS, user,
                             n_predict, ctx)
        for span in _parse_spans(content):
            if not isinstance(span, dict):
                continue
            needle = str(span.get("text", ""))
            if not needle:
                continue
            label = str(span.get("type", "other")).lower()
            ident = _LABEL_TO_IDENTIFIER.get(label, "other_id")
            # Locate the span by its VERBATIM text, not the model's index (small
            # models mis-number). Trust `i` only if it actually contains the
            # needle; otherwise attribute to the first cell in the batch that does.
            try:
                ci = int(span.get("i"))
            except Exception:
                ci = None
            if ci is not None and 0 <= ci < len(chunk) and needle in chunk[ci][1]:
                target = chunk[ci]
            else:
                target = next(((g, f) for (g, f) in chunk if needle in f), None)
            if target is None:                # not a verbatim substring -> drop
                continue
            gidx, full = target
            pos = full.find(needle)
            if pos < 0:
                continue
            out.append({
                "row": gidx + 1,              # 1-based to match R
                "start": pos + 1,             # 1-based
                "end": pos + len(needle),
                "match": full[pos:pos + len(needle)],
                "type": label,
                "identifier": ident,
                "detector": "llm:llamacpp",
                "confidence": 0.6,            # heuristic; a hint for the reviewer
            })
    return out


# ---------------------------------------------------------------------------
# Backend: local Ollama (loopback socket)
# ---------------------------------------------------------------------------

def _client(url: str):
    """Return a callable chat(model, messages) -> content string, or None."""
    # Preferred: the official 'ollama' python client.
    try:
        import ollama  # type: ignore
        client = ollama.Client(host=url)

        def chat(model: str, messages):
            resp = client.chat(model=model, messages=messages,
                               options={"temperature": 0})
            return resp["message"]["content"]
        return chat
    except Exception:
        pass
    # Fallback: plain HTTP via requests to the local /api/chat endpoint.
    try:
        import requests  # type: ignore

        def chat(model: str, messages):
            r = requests.post(
                url.rstrip("/") + "/api/chat",
                json={"model": model, "messages": messages, "stream": False,
                      "options": {"temperature": 0}},
                timeout=60)
            r.raise_for_status()
            return r.json()["message"]["content"]
        return chat
    except Exception:
        return None


def _scan_ollama(texts: List[str], model: str,
                 url: str = "http://127.0.0.1:11434") -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    if not model:
        return out
    chat = _client(url)
    if chat is None:
        return out

    for i, text in enumerate(texts):
        if not text:
            continue
        s = str(text)
        try:
            content = chat(model, [
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": s},
            ])
        except Exception:
            continue
        for span in _parse_spans(content):
            try:
                start = int(span["start"])
                end = int(span["end"])
            except Exception:
                continue
            if start < 0 or end <= start or end > len(s):
                continue
            label = str(span.get("type", "other")).lower()
            ident = _LABEL_TO_IDENTIFIER.get(label, "other_id")
            out.append({
                "row": i + 1,
                "start": start + 1,          # 1-based to match R
                "end": end,
                "match": s[start:end],
                "type": label,
                "identifier": ident,
                "detector": "llm:ollama",
                "confidence": 0.6,           # heuristic; a hint for the reviewer
            })
    return out


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

def llm_scan(texts: List[str], model: str = "",
             url: str = "http://127.0.0.1:11434", backend: str = "",
             llama_bin: str = "", model_path: str = "",
             n_predict: int = 1024, ctx: int = 4096,
             batch: int = 16) -> List[Dict[str, Any]]:
    """Scan a list of strings with the chosen local backend. Keys per span:
    row (1-based), start, end, match, type, identifier, detector, confidence.
    Returns [] if the backend is unavailable. Fails closed."""
    if not backend:
        backend = ("llamacpp" if (llama_bin and model_path)
                   else ("ollama" if model else ""))
    if backend == "llamacpp":
        return _scan_llamacpp(texts, model_path, llama_bin, n_predict, ctx, batch)
    if backend == "ollama":
        return _scan_ollama(texts, model, url)
    return []


# ---------------------------------------------------------------------------
# Headless self-test for the reply parser — no model / binary / network needed,
# so it runs anywhere (and is immune to the AV that quarantines the unsigned
# llama binary on the staging box). Run:  python app/python/detect_llm.py
# Guards the span-object salvage against real small-model output shapes.
# ---------------------------------------------------------------------------

def _selftest() -> int:
    ESC = "\x1b[0m"; GRN = "\x1b[1m\x1b[32m"
    cases = [
        # (label, raw reply, expected number of salvaged span objects)
        # Qwen-style COMPACT one-liner, with the echoed prompt + ANSI colour codes
        ("qwen-compact",
         "\n" + GRN + "\n> inputs = [\"John Tan seen\", \"Mary Goh 9123 4567\"]\n" + ESC +
         "[{\"i\":0,\"text\":\"John Tan\",\"type\":\"name\"},"
         "{\"i\":1,\"text\":\"Mary Goh\",\"type\":\"name\"},"
         "{\"i\":1,\"text\":\"9123 4567\",\"type\":\"phone\"}]\n", 3),
        # MediPhi-style PRETTY-PRINTED complete array (newlines + indentation)
        ("mediphi-pretty",
         "> inputs = [\"...\"]\n[\n"
         "  {\"i\":0,\"text\":\"John Tan\",\"type\":\"name\"},\n"
         "  {\"i\":0,\"text\":\"Sarah Lim\",\"type\":\"name\"},\n"
         "  {\"i\":1,\"text\":\"Mary Goh\",\"type\":\"name\"},\n"
         "  {\"i\":1,\"text\":\"9123 4567\",\"type\":\"phone\"}\n]\n", 4),
        # TRUNCATED pretty array (cut mid-object, no closing ]) -> salvage complete
        ("truncated-salvage",
         "[\n  {\"i\":0,\"text\":\"John Tan\",\"type\":\"name\"},\n"
         "  {\"i\":1,\"text\":\"Mary Goh\",\"type\":\"name\"},\n"
         "  {\"i\":2,\"text\":\"Ahmad bin Ism", 2),
        # Echoed inputs ONLY (completion never produced) -> no dict objects -> []
        ("echoed-only",
         "> inputs = [\"John Tan seen\", \"Mary Goh 9123 4567\"]\n", 0),
        # A brace INSIDE a string value must not break brace-depth tracking
        ("brace-in-string",
         "[{\"i\":0,\"text\":\"weird {name} here\",\"type\":\"name\"}]", 1),
    ]
    fails = 0
    for label, raw, exp in cases:
        got = len(_parse_spans(raw))
        ok = got == exp
        fails += not ok
        print(f"[{'PASS' if ok else 'FAIL'}] {label:18s} expected {exp}, got {got}")
    print("parser self-test:", "OK" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(_selftest())
