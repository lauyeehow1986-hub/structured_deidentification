"""detect_ner.py — free-text NER for the de-identification engine.

Called from R (engine_py.R) via reticulate against the BUNDLED Python only.
Uses Microsoft Presidio (spaCy backend) to find person names, locations,
organisations and other entities that the deterministic R rules miss. Returns a
list of dicts in the shared findings-span schema so results merge with the R
detectors.

Nothing here reaches the network. The spaCy model is bundled under models/ and
loaded by name; if it is missing, ner_scan degrades to an empty result and the
app stays in rules-only mode.
"""

from typing import List, Dict, Any
import os

_ANALYZER = None

# Bundled spaCy model, loaded BY NAME (never downloaded). Overridable so an
# operator can bundle a lighter model (en_core_web_md / _sm) on a tight box.
_MODEL = os.environ.get("SE_SPACY_MODEL", "en_core_web_lg")

# Map Presidio entity labels to our identifier ids (see identifiers.R).
_LABEL_TO_IDENTIFIER = {
    "PERSON": "name",
    "LOCATION": "address",
    "GPE": "address",
    "PHONE_NUMBER": "phone",
    "EMAIL_ADDRESS": "email",
    "IP_ADDRESS": "other_id",
    "URL": "other_id",
    "CREDIT_CARD": "other_id",
    "IBAN_CODE": "other_id",
    "DATE_TIME": "dob",
    "NRP": "other_id",
    "ORGANIZATION": "other_id",
}


def _get_analyzer():
    global _ANALYZER
    if _ANALYZER is not None:
        return _ANALYZER
    from presidio_analyzer import AnalyzerEngine, RecognizerRegistry
    from presidio_analyzer.predefined_recognizers import SpacyRecognizer
    from presidio_analyzer.nlp_engine import NlpEngineProvider

    # Configure spaCy to load a bundled model BY NAME (no download).
    provider = NlpEngineProvider(nlp_configuration={
        "nlp_engine_name": "spacy",
        "models": [{"lang_code": "en", "model_name": _MODEL}],
    })
    nlp_engine = provider.create_engine()

    # AIR-GAP CRITICAL: use a registry with ONLY the spaCy NER recognizer.
    # Presidio's predefined recognizers are (a) redundant with our deterministic
    # R rules (phone/email/credit-card/IBAN/etc.) and (b) the EmailRecognizer
    # pulls in tldextract, which tries to FETCH the public-suffix list over the
    # network on first use — forbidden on the air-gapped box and a hard crash
    # here. Restricting to SpacyRecognizer keeps this pass pure local inference:
    # names, locations, organisations and dates that free text hides.
    registry = RecognizerRegistry()
    registry.add_recognizer(SpacyRecognizer(supported_language="en"))
    _ANALYZER = AnalyzerEngine(nlp_engine=nlp_engine, registry=registry,
                               supported_languages=["en"])
    return _ANALYZER


def ner_scan(texts: List[str], language: str = "en") -> List[Dict[str, Any]]:
    """Scan a list of strings; return one dict per detected span.

    Keys: row (1-based index into `texts`), start, end, match, type,
    identifier, detector, confidence.
    """
    out: List[Dict[str, Any]] = []
    try:
        analyzer = _get_analyzer()
    except Exception:
        return out

    for i, text in enumerate(texts):
        if not text:
            continue
        try:
            results = analyzer.analyze(text=str(text), language=language)
        except Exception:
            continue
        for r in results:
            ident = _LABEL_TO_IDENTIFIER.get(r.entity_type, "other_id")
            out.append({
                "row": i + 1,
                "start": int(r.start) + 1,          # 1-based to match R
                "end": int(r.end),
                "match": str(text)[r.start:r.end],
                "type": r.entity_type.lower(),
                "identifier": ident,
                "detector": "ner:presidio",
                "confidence": float(r.score),
            })
    return out
