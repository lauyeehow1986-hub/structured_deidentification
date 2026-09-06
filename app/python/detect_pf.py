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
