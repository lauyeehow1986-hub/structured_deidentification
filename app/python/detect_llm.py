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
    "Example: inputs = [\"Call Mary Lee at 61234567\"] -> "
    "[{\"i\":0,\"text\":\"Mary Lee\",\"type\":\"name\"},"
    "{\"i\":0,\"text\":\"61234567\",\"type\":\"phone\"}]"
)

# Strip ANSI colour escapes that llama.cpp's console UI wraps output in.
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _parse_spans(content: str):
    """Return the LAST top-level JSON array in the reply that decodes to a list.

    llama.cpp's conversation UI echoes the prompt (which itself contains a JSON
    array of the inputs) and wraps text in ANSI colour codes, so a naive
    first-bracket-to-last-bracket match fails. We strip ANSI, then scan for
    balanced top-level [...] arrays and keep the last one that json-decodes — the
    model's completion comes last, after any echoed input array."""
    if not content:
        return []
    text = _ANSI.sub("", content)
    best = []
    depth = 0
    start = -1
    for idx, ch in enumerate(text):
        if ch == "[":
            if depth == 0:
                start = idx
            depth += 1
        elif ch == "]" and depth > 0:
            depth -= 1
            if depth == 0 and start >= 0:
                try:
                    data = json.loads(text[start:idx + 1])
                    if isinstance(data, list):
                        best = data
                except Exception:
                    pass
                start = -1
    return best


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
             n_predict: int = 512, ctx: int = 4096,
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
