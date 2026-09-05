"""detect_llm.py — OPTIONAL local-LLM (Ollama) pass for ambiguous free text.

Called from R (engine_py.R -> se_llm_scan) via reticulate against the BUNDLED
Python only, and only when the operator has explicitly opted in. It asks a
LOCAL Ollama service (default http://127.0.0.1:11434) to flag spans of personal
data that the deterministic rules and NER may miss in messy free text, and
returns them in the shared findings-span schema so they merge with the other
detectors.

Air-gap note: the ONLY outbound call in this whole system lives here, and it is
a loopback call to a local Ollama the operator chose to bundle and run. There is
no fallback to any remote endpoint. If the client library is missing, the model
is unset, or the service is unreachable, llm_scan returns an empty list and the
app carries on with rules (+NER) only.
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

_SYSTEM = (
    "You are a strict PII detector for clinical free text. "
    "Given ONE input text, return ONLY a compact JSON array (no prose, no code "
    "fences) of objects {\"start\":int,\"end\":int,\"type\":str} for each span "
    "that is personal data. start/end are 0-based character offsets into the "
    "text, end exclusive. type is one of: name, nric, mrn, phone, fax, email, "
    "address, postal, date, other. If nothing is found, return []."
)


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


def _parse_spans(content: str):
    """Pull the first JSON array out of the model reply; tolerate stray text."""
    if not content:
        return []
    m = re.search(r"\[.*\]", content, re.DOTALL)
    if not m:
        return []
    try:
        data = json.loads(m.group(0))
    except Exception:
        return []
    return data if isinstance(data, list) else []


def llm_scan(texts: List[str], model: str,
             url: str = "http://127.0.0.1:11434") -> List[Dict[str, Any]]:
    """Scan a list of strings with a local Ollama model.

    Keys per span: row (1-based index into `texts`), start, end, match, type,
    identifier, detector, confidence. Returns [] if the backend is unavailable.
    """
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
