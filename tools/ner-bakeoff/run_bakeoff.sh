#!/usr/bin/env bash
# V2-P5+ Phase-3 NER bake-off driver.
#
# Runs every neural Core ML candidate (DistilBERT-CoNLL + dslim/bert-base-NER,
# each FP16 + INT8) through the production path (tools/ner-bakeoff), under each
# compute-unit policy (placement attribution), then a sustained footprint loop;
# scores the production (`all`) predictions with eval/ner-corpus/tools/score_ner.py
# on the three neural kinds. The Apple NLTagger A-B floor is run separately
# (nltagger_baseline.swift). REAL measurements only — nothing here is fabricated.
#
# Prereqs:  cargo build --release -p mci-ner-bakeoff
#           .venv-ml/bin/python scripts/convert_ner.py --verify --compile
#           .venv-ml/bin/python scripts/convert_ner.py --model dslim/bert-base-NER --verify --compile
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"

BIN=./target/release/mci-ner-bakeoff
MODELS=${MODELS_DIR:-models}
CORPUS=${CORPUS:-eval/ner-corpus/synthetic/test.json}
SCORER=eval/ner-corpus/tools/score_ner.py
PY=${PY:-.venv-ml/bin/python}
OUT=${OUT_DIR:-/tmp/ner-bakeoff}
KINDS=person_name,organization,location
DUR=${DUR:-60}
mkdir -p "$OUT"
RESULTS="$OUT/results.jsonl"; : > "$RESULTS"

# name | model.mlmodelc | tokenizer.json | labels.json
VARIANTS=(
  "distilbert_FP16|$MODELS/distilbert_NER_FP16.mlmodelc|$MODELS/distilbert_NER_tokenizer/tokenizer.json|$MODELS/distilbert_NER_labels.json"
  "distilbert_INT8|$MODELS/distilbert_NER_INT8.mlmodelc|$MODELS/distilbert_NER_tokenizer/tokenizer.json|$MODELS/distilbert_NER_labels.json"
  "bert_base_FP16|$MODELS/bert_base_NER_FP16.mlmodelc|$MODELS/bert_base_NER_tokenizer/tokenizer.json|$MODELS/bert_base_NER_labels.json"
  "bert_base_INT8|$MODELS/bert_base_NER_INT8.mlmodelc|$MODELS/bert_base_NER_tokenizer/tokenizer.json|$MODELS/bert_base_NER_labels.json"
)

for v in "${VARIANTS[@]}"; do
  IFS='|' read -r name model tok labels <<< "$v"
  echo "### $name  ($(date +%H:%M:%S))"
  # --- predict under each compute-unit policy (placement via latency) ---
  for cu in all cpu gpu cpu_ne; do
    preds="$OUT/${name}_${cu}.preds.json"
    "$BIN" --mode predict --compute-units "$cu" --model "$model" --tokenizer "$tok" \
      --labels "$labels" --corpus "$CORPUS" --out "$preds" --label "$name" \
      2> "$OUT/${name}_${cu}.predict.stderr" | grep '@@RESULT@@' | sed 's/@@RESULT@@ //' >> "$RESULTS"
    echo "  predict[$cu] done"
  done
  # --- official F1 from the production (`all`) predictions ---
  "$PY" "$SCORER" --gold "$CORPUS" --pred "$OUT/${name}_all.preds.json" \
    --kinds "$KINDS" --json-out "$OUT/${name}.score.json" > "$OUT/${name}.score.txt"
  # --- placement must not change outputs (FP16 kernel drift -> note only) ---
  for cu in cpu gpu cpu_ne; do
    cmp -s "$OUT/${name}_all.preds.json" "$OUT/${name}_${cu}.preds.json" \
      || echo "  note: $name preds differ all-vs-$cu (kernel/precision drift)"
  done
  # --- sustained footprint under the production default policy ---
  "$BIN" --mode sustained --compute-units all --duration "$DUR" --rate 1 \
    --model "$model" --tokenizer "$tok" --labels "$labels" --corpus "$CORPUS" --label "$name" \
    2> "$OUT/${name}_sustained.stderr" | grep '@@RESULT@@' | sed 's/@@RESULT@@ //' >> "$RESULTS"
  echo "  sustained done"
done
echo "DONE -> $RESULTS"
