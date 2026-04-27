#!/usr/bin/env python3
"""monitor.py — At-a-glance summary of the meta-harness pilot state.

Walks `candidates/iter-NNNN/` directories, reads their scores.search.json +
notes.md, and prints a compact progress table. Reads
`candidates/pareto-frontier.json` to show the current frontier.

Usage:
  python3 Scripts/meta_harness/monitor.py
"""
from __future__ import annotations
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Match propose.py — HARNESS_ROOT sits outside the repo so writes don't
# trigger Xcode/sourcekit-lsp reindexing.
CAND = Path(
    os.environ.get("HARNESS_ROOT", str(ROOT.parent / "iClaw-candidates"))
).resolve()


def fmt_rate(r: float) -> str:
    return f"{r * 100:5.1f}%"


def main() -> int:
    iters = sorted(CAND.glob("iter-*"))
    if not iters:
        print("no iterations yet")
        return 0

    baseline_rate = None
    baseline_ms = None
    rows = []
    for d in iters:
        scores_path = d / "scores.search.json"
        if not scores_path.exists():
            rows.append((d.name, "pending", None, None, None, None, None))
            continue
        s = json.loads(scores_path.read_text())
        agg = s["aggregate"]
        rate = agg["passRate"]
        ms = agg["avgDurationMs"]
        passed = agg["passed"]
        total = agg["total"]
        misroutes = agg.get("misroutes", 0)
        leaks = agg.get("leaks", 0)
        if baseline_rate is None:
            baseline_rate = rate
            baseline_ms = ms
        rows.append((d.name, "done", rate, ms, passed, total, f"mis={misroutes} leak={leaks}"))

    # Header
    print(f"\n{'iter':<12}  {'status':<8}  {'pass':>6}  {'Δ':>7}  {'avgMs':>6}  {'Δms':>6}  {'p/n':>9}  detail")
    print("-" * 90)
    for (name, status, rate, ms, passed, total, detail) in rows:
        if rate is None:
            print(f"{name:<12}  {status:<8}")
            continue
        delta_rate = (rate - baseline_rate) * 100
        delta_ms = ms - baseline_ms
        delta_s = f"{delta_rate:+5.1f}pp" if delta_rate != 0 else "  —"
        delta_ms_s = f"{int(delta_ms):+d}" if delta_ms else "  —"
        print(f"{name:<12}  {status:<8}  "
              f"{fmt_rate(rate):>6}  {delta_s:>7}  "
              f"{int(ms):>6}  {delta_ms_s:>6}  {passed:>3}/{total:<3}  {detail}")

    # Pareto
    pareto_path = CAND / "pareto-frontier.json"
    if pareto_path.exists():
        pf = json.loads(pareto_path.read_text())
        print(f"\nPareto frontier ({len(pf.get('frontier', []))} entries):")
        for e in pf.get("frontier", []):
            print(f"  {e['iter']:<12}  passRate={fmt_rate(e['passRate'])}  "
                  f"avgMs={int(e['avgDurationMs'])}  ({e['passed']}/{e['total']})")

    # Latest notes.md
    latest = iters[-1]
    notes = latest / "notes.md"
    if notes.exists():
        print(f"\n--- {latest.name}/notes.md (first 30 lines) ---")
        for line in notes.read_text().splitlines()[:30]:
            print(line)

    # Surface biggest per-category regressions in the latest iter
    if rows[-1][1] == "done" and len(iters) > 1:
        latest_scores = json.loads((iters[-1] / "scores.search.json").read_text())
        first_scores = json.loads((iters[0] / "scores.search.json").read_text())
        lat = latest_scores["aggregate"].get("byCategory", {})
        fst = first_scores["aggregate"].get("byCategory", {})
        diffs = []
        for cat in sorted(set(lat) & set(fst)):
            delta = lat[cat]["passRate"] - fst[cat]["passRate"]
            diffs.append((delta, cat, fst[cat]["passRate"], lat[cat]["passRate"]))
        diffs.sort()
        if diffs:
            print(f"\nLargest per-category shifts vs baseline ({iters[0].name}):")
            for d in diffs[:5]:
                if d[0] < 0:
                    print(f"  ✘ {d[1]:<22}  {fmt_rate(d[2]):>6} → {fmt_rate(d[3]):>6}  "
                          f"({d[0] * 100:+.1f}pp)")
            for d in diffs[-3:]:
                if d[0] > 0:
                    print(f"  ✓ {d[1]:<22}  {fmt_rate(d[2]):>6} → {fmt_rate(d[3]):>6}  "
                          f"({d[0] * 100:+.1f}pp)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
