#!/usr/bin/env python3
"""split_corpus.py — Freeze a held-out test split (deterministic).

Reads every prompt corpus under MLTraining/ (autonomous-baseline + cycle-probes),
stratifies by category, and writes `candidates/test-set.lock` containing the
IDs of the held-out ~20%. This file is read by evaluate.py to filter prompts
by split. The proposer MUST NOT read the test side.

Runs once per project; re-running without --force is a no-op (existing lock
is preserved to avoid the proposer ever learning the test set).
"""
from __future__ import annotations
import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCES = [
    ROOT / "MLTraining" / "autonomous-baseline.json",
] + sorted((ROOT / "MLTraining" / "cycle-probes").glob("*.json"))
DEFAULT_LOCK = ROOT / "candidates" / "test-set.lock"


def collect(paths: list[Path]) -> list[dict]:
    prompts: list[dict] = []
    for p in paths:
        with open(p) as f:
            spec = json.load(f)
        for e in spec.get("prompts", []):
            prompts.append({
                "id": e["id"],
                "category": e.get("category", p.stem),
                "corpus": p.stem,
            })
    return prompts


def stratified_sample(prompts: list[dict], fraction: float, seed: int) -> list[str]:
    rng = random.Random(seed)
    by_cat: dict[str, list[str]] = {}
    for p in prompts:
        by_cat.setdefault(p["category"], []).append(p["id"])
    test: list[str] = []
    for cat, ids in sorted(by_cat.items()):
        k = max(1, round(len(ids) * fraction))
        ids_sorted = sorted(ids)  # deterministic ordering before shuffle
        rng.shuffle(ids_sorted)
        test.extend(ids_sorted[:k])
    return sorted(test)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fraction", type=float, default=0.2,
                    help="held-out fraction per category (default 0.2)")
    ap.add_argument("--seed", type=int, default=20260421,
                    help="RNG seed for reproducibility")
    ap.add_argument("--out", type=Path, default=DEFAULT_LOCK)
    ap.add_argument("--force", action="store_true",
                    help="overwrite existing lock (caution: leaks test set to prior iters)")
    args = ap.parse_args()

    if args.out.exists() and not args.force:
        print(f"{args.out} already exists — refusing to overwrite without --force",
              file=sys.stderr)
        return 1

    prompts = collect(DEFAULT_SOURCES)
    test_ids = stratified_sample(prompts, args.fraction, args.seed)

    lock = {
        "version": 1,
        "seed": args.seed,
        "fraction": args.fraction,
        "sources": [p.name for p in DEFAULT_SOURCES],
        "totalPrompts": len(prompts),
        "testCount": len(test_ids),
        "searchCount": len(prompts) - len(test_ids),
        "test": test_ids,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(lock, f, indent=2)
    print(f"wrote {args.out}: {len(test_ids)} test / "
          f"{len(prompts) - len(test_ids)} search across "
          f"{len({p['category'] for p in prompts})} categories", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
