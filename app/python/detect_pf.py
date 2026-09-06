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
