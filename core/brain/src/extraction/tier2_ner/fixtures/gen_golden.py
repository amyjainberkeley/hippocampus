#!/usr/bin/env python3
"""Generate golden NER fixtures for the V2-P5+ Tier-2 supervised
token-classifier (`dslim/distilbert-NER`, CoNLL-2003, bert-base-cased
WordPiece).

These fixtures are the make-or-break gate for the pure-Rust
`tier2_ner::tokenizer` (offset mapping) and `tier2_ner::decoder` (BIO
span merge). The Rust unit tests assert that:

  (a) the Rust tokenizer reproduces HF `input_ids`, `special_tokens_mask`
      and **byte** offsets EXACTLY, and
  (b) the Rust BIO decoder, fed the per-token `logits` recorded here,
      reproduces HF's `aggregation_strategy="simple"` entity spans
      EXACTLY (type + byte span; confidence within a float tolerance).

Run (from the repo root, with the provisioned ML venv):

    .venv-ml/bin/python \
        core/brain/src/extraction/tier2_ner/fixtures/gen_golden.py

Output (committed):
  - core/brain/src/extraction/tier2_ner/fixtures/distilbert_ner_golden.json
  - core/brain/src/extraction/tier2_ner/resources/tokenizer.json
  - core/brain/src/extraction/tier2_ner/resources/config.json

The script is deterministic: model in eval mode, no dropout, no
sampling, fixed sentence list. It mirrors the exact HF algorithm in
`transformers/pipelines/token_classification.py` (SIMPLE strategy) and
cross-checks the manual replication against the real `pipeline(...)`
output so the recorded `logits` + recorded `expected` spans are
internally consistent.
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np
import torch
from huggingface_hub import hf_hub_download
from transformers import (
    AutoConfig,
    AutoModelForTokenClassification,
    AutoTokenizer,
    pipeline,
)

MODEL = "dslim/distilbert-NER"

HERE = Path(__file__).resolve().parent
RES = HERE.parent / "resources"
RES.mkdir(parents=True, exist_ok=True)

# CoNLL tag -> our V2-P5 entity-kind constant (see core/brain/src/
# extraction/tier2.rs KIND_* constants). MISC and O are dropped.
TAG_TO_KIND = {
    "PER": "person_name",
    "ORG": "organization",
    "LOC": "location",
    # MISC -> dropped (not in our schema)
}

# ~14 representative sentences. Deliberately NOT just clean newswire:
# screen-text flavored fragments (ALL-CAPS, UI chrome, an email header),
# multibyte accents, a CJK-ish name, a MISC-only sentence (to prove MISC
# is dropped), and a negative (no-entity) UI row.
SENTENCES = [
    # clean newswire — PER / ORG / LOC
    "Alice Smith met Bob at Anthropic in San Francisco.",
    # two PER + LOC
    "Barack Obama visited Berlin and met Angela Merkel.",
    # ORG + product(MISC-ish) + LOC
    "Apple Inc. announced the iPhone in Cupertino.",
    # ALL-CAPS screen text (UI title bar / heading)
    "MEETING WITH SATYA NADELLA AT MICROSOFT HQ",
    # email header / UI fragment with an ORG
    "From: jane.doe@example.com Subject: Q3 sync with Stripe",
    # titled persons + project + ORG
    "Dr. Chen and Dr. Patel reviewed the project at New Tandem.",
    # multibyte accents — PER / ORG / LOC
    "José works at Café Réunion in Montréal.",
    # multi-word ORG + LOC
    "The New York Times reported from Washington.",
    # romanized Japanese name (ASCII) + two LOC
    "Kenji Tanaka flew from Tokyo to London.",
    # negative — UI chrome, no entities
    "OK Cancel Save Settings Account Privacy",
    # PER + two adjacent ORG
    "Elon Musk leads Tesla and SpaceX.",
    # subword-heavy ORG / product
    "Nadella spoke about Kubernetes and Microsoft Azure.",
    # MISC trigger (nationality / award) — must be dropped
    "He won the German Grand Prix and a Nobel Prize.",
    # short / punctuation-heavy
    "RE: Re: FWD: status?",
    # empty string — pins [CLS][SEP]-only encode + zero entities
    "",
    # REAL CJK (3-byte UTF-8) — BertNormalizer.handle_chinese_chars splits
    # each ideograph into its own token; the model is English-only so it
    # mostly labels O, but this pins byte-offset fidelity across 3-byte
    # boundaries (the tokenizer's whole reason to exist).
    "张三 works at 阿里巴巴 in 北京 with Alice",
    # emoji (4-byte UTF-8) interleaved with a real PER — pins byte offsets
    # across the widest UTF-8 code units and [UNK] handling.
    "🚀 Alice Smith launched 🎉 at Anthropic",
]


def softmax_np(logits: np.ndarray) -> np.ndarray:
    maxes = np.max(logits, axis=-1, keepdims=True)
    shifted = np.exp(logits - maxes)
    return shifted / shifted.sum(axis=-1, keepdims=True)


def get_tag(label: str) -> tuple[str, str]:
    if label.startswith("B-"):
        return "B", label[2:]
    if label.startswith("I-"):
        return "I", label[2:]
    return "I", label


def manual_simple(
    logits: np.ndarray,
    offsets: list[tuple[int, int]],
    special_tokens_mask: list[int],
    id2label: dict[int, str],
) -> list[dict]:
    """Faithful numpy replication of HF SIMPLE aggregation. Used only to
    cross-check the recorded logits + the real pipeline agree."""
    scores = softmax_np(logits)
    per_token = []
    for idx in range(len(scores)):
        if special_tokens_mask[idx]:
            continue
        ti = int(scores[idx].argmax())
        per_token.append(
            {
                "entity": id2label[ti],
                "score": float(scores[idx][ti]),
                "start": offsets[idx][0],
                "end": offsets[idx][1],
            }
        )
    # group_entities
    groups: list[list[dict]] = []
    cur: list[dict] = []
    for ent in per_token:
        if not cur:
            cur = [ent]
            continue
        bi, tag = get_tag(ent["entity"])
        _, last_tag = get_tag(cur[-1]["entity"])
        if tag == last_tag and bi != "B":
            cur.append(ent)
        else:
            groups.append(cur)
            cur = [ent]
    if cur:
        groups.append(cur)
    out = []
    for g in groups:
        tag = g[0]["entity"].split("-", 1)[-1]
        if tag == "O":
            continue
        out.append(
            {
                "entity_group": tag,
                "score": float(np.mean([m["score"] for m in g])),
                "start": g[0]["start"],
                "end": g[-1]["end"],
            }
        )
    return out


def char_to_byte(text: str, char_idx: int) -> int:
    return len(text[:char_idx].encode("utf-8"))


def main() -> None:
    # Bundle the tokenizer + config as committed resources.
    tok_json = hf_hub_download(MODEL, "tokenizer.json")
    cfg_json = hf_hub_download(MODEL, "config.json")
    shutil.copyfile(tok_json, RES / "tokenizer.json")
    shutil.copyfile(cfg_json, RES / "config.json")

    config = AutoConfig.from_pretrained(MODEL)
    id2label = {int(k): v for k, v in config.id2label.items()}
    label_list = [id2label[i] for i in range(len(id2label))]

    tokenizer = AutoTokenizer.from_pretrained(MODEL)
    assert tokenizer.is_fast, "need the fast (Rust-backed) tokenizer for offsets"
    model = AutoModelForTokenClassification.from_pretrained(MODEL)
    model.eval()
    model.to("cpu")  # keep manual forward + pipeline on the same (CPU) device

    nlp = pipeline(
        "token-classification",
        model=model,
        tokenizer=tokenizer,
        aggregation_strategy="simple",
        device="cpu",
    )

    cases = []
    for text in SENTENCES:
        enc = tokenizer(
            text,
            return_offsets_mapping=True,
            return_special_tokens_mask=True,
            return_tensors="pt",
        )
        input_ids = enc["input_ids"][0].tolist()
        attention_mask = enc["attention_mask"][0].tolist()
        special_tokens_mask = enc["special_tokens_mask"][0].tolist()
        offsets_char = [list(o) for o in enc["offset_mapping"][0].tolist()]

        with torch.no_grad():
            logits_t = model(
                input_ids=enc["input_ids"],
                attention_mask=enc["attention_mask"],
            ).logits[0]
        logits = logits_t.numpy().astype(np.float32)

        # Byte offsets for every token (Tier2RawMatch uses byte spans).
        # Special tokens map to (0,0) in HF -> keep (0,0).
        offsets_byte = []
        for (s, e) in offsets_char:
            if s == 0 and e == 0:
                offsets_byte.append([0, 0])
            else:
                offsets_byte.append([char_to_byte(text, s), char_to_byte(text, e)])

        argmax_labels = [
            label_list[int(r.argmax())] for r in softmax_np(logits)
        ]

        # Ground truth from the REAL pipeline (char offsets).
        hf_ents = nlp(text)
        hf_entities = []
        for ent in hf_ents:
            cs, ce = int(ent["start"]), int(ent["end"])
            hf_entities.append(
                {
                    "entity_group": ent["entity_group"],
                    "word": ent["word"],
                    "start_char": cs,
                    "end_char": ce,
                    "start_byte": char_to_byte(text, cs),
                    "end_byte": char_to_byte(text, ce),
                    "score": float(ent["score"]),
                }
            )

        # Cross-check: manual replication on recorded logits must equal
        # the pipeline's char spans + types (scores within 1e-5).
        manual = manual_simple(logits, offsets_char, special_tokens_mask, id2label)
        assert len(manual) == len(hf_entities), (
            f"manual vs pipeline count mismatch for {text!r}: "
            f"{manual} vs {hf_entities}"
        )
        for m, h in zip(manual, hf_entities):
            assert m["entity_group"] == h["entity_group"], (text, m, h)
            assert m["start"] == h["start_char"], (text, m, h)
            assert m["end"] == h["end_char"], (text, m, h)
            assert abs(m["score"] - h["score"]) < 1e-5, (text, m, h)

        # `expected` = pipeline entities mapped to our kinds, MISC/O
        # dropped, byte spans. This is what the Rust decoder must emit.
        expected = []
        for ent in hf_entities:
            kind = TAG_TO_KIND.get(ent["entity_group"])
            if kind is None:
                continue  # MISC dropped
            expected.append(
                {
                    "kind": kind,
                    "text": text.encode("utf-8")[ent["start_byte"] : ent["end_byte"]].decode("utf-8"),
                    "span_start": ent["start_byte"],
                    "span_end": ent["end_byte"],
                    "confidence": ent["score"],
                }
            )

        cases.append(
            {
                "text": text,
                "input_ids": input_ids,
                "attention_mask": attention_mask,
                "special_tokens_mask": special_tokens_mask,
                "offsets_char": offsets_char,
                "offsets_byte": offsets_byte,
                "logits": [[float(x) for x in row] for row in logits.tolist()],
                "argmax_labels": argmax_labels,
                "hf_entities_simple": hf_entities,
                "expected": expected,
            }
        )

    out = {
        "model": MODEL,
        "model_type": config.model_type,
        "id2label": label_list,
        "tag_to_kind": TAG_TO_KIND,
        "aggregation_strategy": "simple",
        "transformers_version": __import__("transformers").__version__,
        "tokenizers_version": __import__("tokenizers").__version__,
        "note": "Generated by gen_golden.py. byte offsets are UTF-8 byte indices into `text`; special tokens map to [0,0].",
        "cases": cases,
    }

    out_path = HERE / "distilbert_ner_golden.json"
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(f"wrote {out_path} ({len(cases)} cases)")
    print(f"wrote {RES / 'tokenizer.json'}")
    print(f"wrote {RES / 'config.json'}")
    # Quick summary
    total_expected = sum(len(c["expected"]) for c in cases)
    total_hf = sum(len(c["hf_entities_simple"]) for c in cases)
    print(f"HF entities (incl MISC): {total_hf}; expected (PER/ORG/LOC): {total_expected}")


if __name__ == "__main__":
    main()
