#!/usr/bin/env python3
"""Merge userfact_data.jsonl, dedupe, stratified 85/15 split.

Produces:
  MLTraining/userfact_training.json
  MLTraining/userfact_validation.json
"""
import json
import random
import sys
from pathlib import Path
from collections import Counter

SEED = 42
SPLIT_RATIO = 0.85
VALID_LABELS = {
    "none", "self_identity", "dietary", "family",
    "location_fact", "work_fact", "preference",
}
# None is the default class in production traffic — cap at 800 so it
# doesn't dwarf the other classes and bias the classifier toward "none".
PER_CLASS_CAP = {"none": 800}

root = Path(__file__).resolve().parent
inputs = [root / "userfact_data.jsonl"]
out_train = root / "userfact_training.json"
out_val = root / "userfact_validation.json"


def load_jsonl(path):
    records = []
    if not path.exists():
        print(f"WARN: {path} missing", file=sys.stderr)
        return records
    with path.open() as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"  {path.name}:{line_num} bad JSON: {e}", file=sys.stderr)
                continue
            text = rec.get("text")
            label = rec.get("label")
            if not isinstance(text, str) or not isinstance(label, str):
                continue
            text = text.strip()
            if not text or len(text) < 2:
                continue
            if label not in VALID_LABELS:
                print(f"  {path.name}:{line_num} invalid label {label!r}", file=sys.stderr)
                continue
            records.append({"text": text, "label": label})
    return records


def main():
    all_records = []
    for p in inputs:
        before = len(all_records)
        all_records.extend(load_jsonl(p))
        print(f"Loaded {len(all_records) - before} from {p.name}")

    seen = set()
    unique = []
    for r in all_records:
        key = (r["text"].lower(), r["label"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)
    print(f"After dedupe: {len(unique)} (removed {len(all_records) - len(unique)})")

    random.seed(SEED)
    if PER_CLASS_CAP:
        by_label_tmp: dict = {}
        for r in unique:
            by_label_tmp.setdefault(r["label"], []).append(r)
        capped = []
        for label, recs in by_label_tmp.items():
            cap = PER_CLASS_CAP.get(label)
            if cap is not None and len(recs) > cap:
                random.shuffle(recs)
                print(f"  Capped {label}: {len(recs)} -> {cap}")
                capped.extend(recs[:cap])
            else:
                capped.extend(recs)
        unique = capped
        print(f"After capping: {len(unique)}")

    counts = Counter(r["label"] for r in unique)
    print("Label distribution:")
    for label, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {label:<18} {n:>5}")

    by_label = {}
    for r in unique:
        by_label.setdefault(r["label"], []).append(r)
    train = []
    val = []
    for label, recs in by_label.items():
        random.shuffle(recs)
        cut = int(len(recs) * SPLIT_RATIO)
        train.extend(recs[:cut])
        val.extend(recs[cut:])

    random.shuffle(train)
    random.shuffle(val)

    out_train.write_text(json.dumps(train, ensure_ascii=False))
    out_val.write_text(json.dumps(val, ensure_ascii=False))
    print(f"Wrote {len(train)} train -> {out_train.name}")
    print(f"Wrote {len(val)} val   -> {out_val.name}")


if __name__ == "__main__":
    main()
