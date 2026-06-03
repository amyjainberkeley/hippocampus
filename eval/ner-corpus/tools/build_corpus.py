#!/usr/bin/env python3
"""Build the MCI synthetic screen-text NER corpus from inline-markup samples.

This is the deterministic, reproducible half of the corpus pipeline. The
LLM fleet produces *marked* text (entities wrapped in sentinels); this
script turns that into the frozen, byte-offset-labeled corpus JSON that
the Phase-3 bake-off scorer (`score_ner.py`) consumes.

Why markup -> code-computed offsets (and not LLM-emitted offsets):
    LLMs are unreliable at counting character/byte offsets, especially on
    OCR-noised or truncated text. So the generator only has to *draw the
    span* (wrap the entity); this script computes the exact UTF-8 byte
    offsets by a single left-to-right parse. The labels are therefore
    guaranteed self-consistent: `text.encode()[s:e].decode() == mention`
    holds by construction, and the gold-vs-gold scorer self-test is a
    trivial F1 == 1.0.

Schema match (verify-audit against core/brain/src/extraction, main@2983fc9):
    Each gold entity mirrors the in-memory schema that BOTH V2-P4
    `Tier1Match` and V2-P5 `Tier2Match` emit:
        { kind, span_start, span_end, mention_text }
    - span_start: inclusive UTF-8 byte offset into `text`
    - span_end:   exclusive UTF-8 byte offset into `text`
    - invariant:  text.encode('utf-8')[span_start:span_end].decode() == mention_text
                  (this is exactly the Tier2 extractor's `verify_span` check)
    `canonical_name` is intentionally OMITTED from gold: it is an
    extractor-side normalization (title-case for people, digits-only for
    phones, ...), not a labeling target. The bake-off scores span
    detection + kind classification, keyed on (kind, span_start, span_end).

Kind strings (locked in code unless noted):
    person_name   core/brain/src/extraction/tier2.rs::KIND_PERSON_NAME
    organization  core/brain/src/extraction/tier2.rs::KIND_ORGANIZATION
    location      core/brain/src/extraction/tier2.rs::KIND_LOCATION
    date          Director-defined (see README "Date/Time fork"): NOT yet
    time          in code. PR #282 (V2-P4 tier1.rs) ships no date/time
                  regex. The scorer's KIND set is config-driven so a future
                  rename costs one line.

Usage:
    python3 build_corpus.py --raw raw/raw_marked_samples.json --out-dir synthetic
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Schema constants (verify-audit pinned)
# ---------------------------------------------------------------------------

# The 5 evaluation kinds, in the exact `entities.kind` strings the MCI
# extractor surface uses. person_name / organization / location are locked
# in core/brain/src/extraction/tier2.rs; date / time are Director-defined
# (see README) pending the V2-P4 Date/Time regex.
KINDS = ["person_name", "organization", "location", "date", "time"]

# Inline-markup sentinels. Chosen to be effectively impossible in real
# screen text: U+27E6 / U+22B3 / U+27E7. They appear ONLY as entity
# wrappers; any occurrence in the *clean* text is treated as malformed.
OPEN = "⟦"   # ⟦
SEP = "⊳"    # ⊳
CLOSE = "⟧"  # ⟧
SENTINELS = (OPEN, SEP, CLOSE)

ENTITY_RE = re.compile(
    re.escape(OPEN) + r"(?P<kind>[a-z_]+)" + re.escape(SEP) + r"(?P<surface>.*?)" + re.escape(CLOSE),
    re.DOTALL,
)

# Canonical hardness-tag vocabulary. Agent-emitted tags are filtered to
# this set (some agents leaked genre/kind strings into the tag list).
# `zero_entity` / `multi_entity` are additionally DERIVED from the true
# entity count below so they are authoritative regardless of agent tagging.
CANON_TAGS = {
    "ocr_noise", "all_caps", "mixed_case", "truncated", "no_boundary",
    "ui_chrome_interleaved", "ambiguous_token", "multi_entity",
    "hard_negative", "zero_entity",
}

# Deterministic dev fraction (per (genre,variant) stratum, round-robin).
DEV_EVERY = 5      # of every 5 samples in a stratum,
DEV_TAKE = 2       # the first 2 go to dev (40% dev / 60% test), stably.


def normalize_tags(raw_tags: list[str], n_entities: int) -> list[str]:
    tags = {t for t in raw_tags if t in CANON_TAGS}
    # Derive the count-dependent tags authoritatively.
    tags.discard("zero_entity")
    tags.discard("multi_entity")
    if n_entities == 0:
        tags.add("zero_entity")
        tags.add("hard_negative")
    elif n_entities >= 3:
        tags.add("multi_entity")
    return sorted(tags)


# ---------------------------------------------------------------------------
# Markup parser  ->  (clean_text, entities[])  with code-computed byte offsets
# ---------------------------------------------------------------------------

class ParseError(Exception):
    pass


def parse_marked(marked: str) -> tuple[str, list[dict]]:
    """Parse one ⟦KIND⊳SURFACE⟧-annotated string.

    Returns (clean_text, entities). Entities carry inclusive/exclusive
    UTF-8 byte offsets into clean_text and the literal mention surface.
    Raises ParseError on any malformed markup (unknown kind, empty
    surface, or a stray sentinel left in the clean text).
    """
    clean_parts: list[str] = []
    entities: list[dict] = []
    byte_len = 0  # running UTF-8 byte length of clean text so far
    pos = 0

    for m in ENTITY_RE.finditer(marked):
        # Literal run before this entity.
        literal = marked[pos:m.start()]
        clean_parts.append(literal)
        byte_len += len(literal.encode("utf-8"))

        kind = m.group("kind")
        surface = m.group("surface")
        if kind not in KINDS:
            raise ParseError(f"unknown kind {kind!r}")
        if surface == "" or surface.strip() == "":
            raise ParseError(f"empty surface for kind {kind!r}")
        if surface != surface.strip():
            # Tight-span discipline: no leading/trailing whitespace.
            raise ParseError(f"untrimmed surface {surface!r}")

        span_start = byte_len
        clean_parts.append(surface)
        byte_len += len(surface.encode("utf-8"))
        span_end = byte_len

        entities.append(
            {
                "kind": kind,
                "span_start": span_start,
                "span_end": span_end,
                "mention_text": surface,
            }
        )
        pos = m.end()

    # Trailing literal.
    clean_parts.append(marked[pos:])
    clean = "".join(clean_parts)

    # No sentinel may survive into the clean text (would indicate an
    # unbalanced/garbled wrapper or a sentinel used as content).
    for s in SENTINELS:
        if s in clean:
            raise ParseError(f"stray sentinel {s!r} in clean text")

    # Redundant safety: the byte-slice invariant the Rust extractor checks.
    blob = clean.encode("utf-8")
    for e in entities:
        got = blob[e["span_start"]:e["span_end"]].decode("utf-8")
        if got != e["mention_text"]:
            raise ParseError(
                f"offset invariant broken: [{e['span_start']}:{e['span_end']}] -> {got!r} != {e['mention_text']!r}"
            )

    # Within a sample, no two entities may share identical (start,end).
    seen = set()
    for e in entities:
        key = (e["span_start"], e["span_end"], e["kind"])
        if key in seen:
            raise ParseError(f"duplicate span {key}")
        seen.add(key)

    return clean, entities


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

def norm_for_dedup(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


def build(raw_samples: list[dict]) -> tuple[list[dict], dict, list[dict]]:
    records: list[dict] = []
    dropped: list[dict] = []
    dedup_seen: dict[str, str] = {}
    counter: dict[tuple[str, str], int] = defaultdict(int)

    for raw in raw_samples:
        genre = raw.get("genre", "unknown")
        variant = raw.get("variant", "unknown")
        marked = raw.get("marked_text", "")
        try:
            clean, entities = parse_marked(marked)
        except ParseError as exc:
            dropped.append({"genre": genre, "variant": variant, "reason": str(exc), "marked_text": marked})
            continue

        if not clean.strip():
            dropped.append({"genre": genre, "variant": variant, "reason": "empty clean text", "marked_text": marked})
            continue

        key = norm_for_dedup(clean)
        if key in dedup_seen:
            dropped.append({"genre": genre, "variant": variant, "reason": f"duplicate of {dedup_seen[key]}", "marked_text": marked})
            continue

        idx = counter[(genre, variant)]
        counter[(genre, variant)] += 1
        rid = f"{genre}-{variant}-{idx:04d}"
        dedup_seen[key] = rid

        records.append(
            {
                "id": rid,
                "genre": genre,
                "variant": variant,
                "text": clean,
                "entities": entities,
                "hardness_tags": normalize_tags(raw.get("hardness_tags", []), len(entities)),
            }
        )

    # Deterministic stratified dev/test split: stable order by id within
    # each (genre,variant) stratum, round-robin DEV_TAKE of every DEV_EVERY.
    records.sort(key=lambda r: r["id"])
    strat_counter: dict[tuple[str, str], int] = defaultdict(int)
    for r in records:
        strat = (r["genre"], r["variant"])
        i = strat_counter[strat]
        strat_counter[strat] += 1
        r["split"] = "dev" if (i % DEV_EVERY) < DEV_TAKE else "test"

    stats = compute_stats(records, dropped)
    return records, stats, dropped


def compute_stats(records: list[dict], dropped: list[dict]) -> dict:
    per_kind = Counter()
    per_kind_split = defaultdict(Counter)
    per_genre = Counter()
    per_variant = Counter()
    per_split = Counter()
    hardness = Counter()
    zero_entity = 0
    multi_entity = 0
    total_mentions = 0

    for r in records:
        per_genre[r["genre"]] += 1
        per_variant[r["variant"]] += 1
        per_split[r["split"]] += 1
        for t in r["hardness_tags"]:
            hardness[t] += 1
        n = len(r["entities"])
        total_mentions += n
        if n == 0:
            zero_entity += 1
        if n >= 3:
            multi_entity += 1
        for e in r["entities"]:
            per_kind[e["kind"]] += 1
            per_kind_split[r["split"]][e["kind"]] += 1

    return {
        "samples": len(records),
        "dropped": len(dropped),
        "drop_reasons": Counter(d["reason"].split(":")[0].split(" of ")[0] for d in dropped),
        "total_mentions": total_mentions,
        "zero_entity_samples": zero_entity,
        "multi_entity_samples": multi_entity,
        "per_kind": dict(per_kind),
        "per_kind_dev": dict(per_kind_split["dev"]),
        "per_kind_test": dict(per_kind_split["test"]),
        "per_genre": dict(per_genre),
        "per_variant": dict(per_variant),
        "per_split": dict(per_split),
        "hardness": dict(hardness),
    }


def write_corpus(records: list[dict], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    full = [{k: v for k, v in r.items() if k != "split"} for r in records]
    dev = [{k: v for k, v in r.items() if k != "split"} for r in records if r["split"] == "dev"]
    test = [{k: v for k, v in r.items() if k != "split"} for r in records if r["split"] == "test"]
    for name, data in [("corpus.full.json", full), ("dev.json", dev), ("test.json", test)]:
        (out_dir / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Build MCI synthetic screen-text NER corpus from marked samples.")
    ap.add_argument("--raw", required=True, type=Path, help="raw marked-samples JSON (list of {genre,variant,marked_text,hardness_tags})")
    ap.add_argument("--out-dir", required=True, type=Path, help="output dir for corpus.full.json / dev.json / test.json")
    ap.add_argument("--manifest", type=Path, default=None, help="optional path to write stats manifest JSON")
    ap.add_argument("--dropped-out", type=Path, default=None, help="optional path to write dropped-sample debug JSON")
    args = ap.parse_args()

    raw = json.loads(args.raw.read_text(encoding="utf-8"))
    if isinstance(raw, dict) and "samples" in raw:
        raw = raw["samples"]
    if not isinstance(raw, list):
        print("ERROR: raw input must be a JSON list (or {samples:[...]})", file=sys.stderr)
        return 2

    records, stats, dropped = build(raw)
    write_corpus(records, args.out_dir)

    if args.manifest:
        args.manifest.write_text(json.dumps(stats, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.dropped_out:
        args.dropped_out.write_text(json.dumps(dropped, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("=== MCI synthetic screen-text NER corpus — build stats ===")
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
