"""run_engine.py — out-of-process entry point for the optional Python engines.

R (engine_py.R) invokes the BUNDLED interpreter as a subprocess:

    <bundle>/bin/python/python.exe app/python/run_engine.py <mode>

reading a JSON request from stdin and writing a JSON response to stdout. Running
out-of-process (rather than embedding Python in R via reticulate) keeps the two
runtimes' native libraries apart — on Windows, R's OpenSSL and a standalone
Python's OpenSSL cannot safely share one process (the classic
"no OPENSSL_Applink" crash) — and makes the air-gap boundary trivial to audit:
the app never initialises Python in-process and never provisions anything.

Modes:
  probe : stdin {}                          -> {"presidio":bool,"spacy":bool,"ollama":bool}
  ner   : stdin {"texts":[...]}             -> [ span, ... ]   (see detect_ner.py)
  pf    : stdin {"texts":[...],"model_dir":.} -> [ span, ... ]   (see detect_pf.py)
  llm   : stdin {"texts":[...],"backend":.} -> [ span, ... ]   (see detect_llm.py)
          backend "llamacpp" (socket-free, needs llama_bin+model_path) or
          "ollama" (loopback socket to a local Ollama).

stdout is ALWAYS a single JSON value; on any failure it degrades to an empty
result so the caller falls back to rules-only.
"""

import sys
import os
import json


def _forbid_network():
    """Hard-disable outbound network for the NER/probe passes. Local NER needs
    no network; this enforces the air-gap in code so a mis-behaving dependency
    (e.g. tldextract trying to fetch the public-suffix list) cannot phone home.
    The LLM pass is exempt because it must reach a LOCAL Ollama on loopback."""
    import socket

    def _blocked(*_a, **_k):
        raise OSError("network disabled (air-gapped NER pass)")

    socket.socket.connect = _blocked          # type: ignore[assignment]
    socket.socket.connect_ex = _blocked       # type: ignore[assignment]
    socket.create_connection = _blocked       # type: ignore[assignment]


def _read_request():
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def _probe():
    out = {}
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


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    req = _read_request()
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)

    # The llm pass is allowed a loopback socket ONLY for the ollama backend; the
    # socket-free llamacpp backend (and probe/ner) run with the network disabled.
    if mode in ("probe", "ner", "pf") or (mode == "llm" and req.get("backend", "") != "ollama"):
        _forbid_network()

    result = []
    try:
        if mode == "probe":
            result = _probe()
        elif mode == "ner":
            import detect_ner
            result = detect_ner.ner_scan(req.get("texts", []))
        elif mode == "pf":
            import detect_pf
            result = detect_pf.pf_scan(req.get("texts", []), req.get("model_dir", ""))
        elif mode == "llm":
            import detect_llm
            result = detect_llm.llm_scan(
                req.get("texts", []),
                model=req.get("model", ""),
                url=req.get("url", "http://127.0.0.1:11434"),
                backend=req.get("backend", ""),
                llama_bin=req.get("llama_bin", ""),
                model_path=req.get("model_path", ""),
                n_predict=int(req.get("n_predict", 512)),
                ctx=int(req.get("ctx", 4096)),
                batch=int(req.get("batch", 16)))
    except Exception:
        result = {} if mode == "probe" else []

    sys.stdout.write(json.dumps(result))


if __name__ == "__main__":
    main()
