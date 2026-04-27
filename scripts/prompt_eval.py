#!/usr/bin/env python3
"""prompt_eval.py — Compare prompt variants across a probe suite.

Drives the iClawCLI with `UserDefaults` overrides that select alternate
prompt variants, runs the autonomous regression suite for each variant,
and prints a comparison leaderboard.

Example:
    python3 Scripts/prompt_eval.py \
        --prompt brain \
        --variants "" v2-preserve \
        --suite MLTraining/autonomous-baseline.json \
        --runs 2

Variant "" (empty string) = the default (BRAIN.md). Other variants resolve
to `BRAIN.{variant}.md` via `BrainProvider`.

Scoring: reuses `autonomous_cycle.py`'s deterministic rubric (routing,
leakage, pivot-echo, mustContain, widget match, duration). Aggregates to
per-variant pass rate, per-metric rate, avg duration. Reports significant
deltas across variants.
"""
from __future__ import annotations
import argparse
import json
import os
import subprocess
import sys
from typing import Any

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CYCLE = os.path.join(ROOT, "Scripts", "autonomous_cycle.py")


def run_variant(prompt_id: str, variant: str, suite: str, out_path: str) -> dict:
    """Run the autonomous cycle with the given variant and return the report.
    `variant` may be a bundle variant name (`v2-preserve`) or a filesystem
    path to a markdown file. Paths are auto-detected by `os.path.exists`.
    """
    variant_key = f"prompt.{prompt_id}.variant"
    path_key = f"{variant_key}.path"

    # Clear both first so stale overrides don't linger.
    subprocess.run(["defaults", "delete", "NSGlobalDomain", variant_key],
                   capture_output=True)
    subprocess.run(["defaults", "delete", "NSGlobalDomain", path_key],
                   capture_output=True)

    if variant and os.path.exists(variant):
        # Filesystem path override
        subprocess.run(["defaults", "write", "NSGlobalDomain", path_key, variant],
                       capture_output=True, text=True)
    elif variant:
        subprocess.run(["defaults", "write", "NSGlobalDomain", variant_key, variant],
                       capture_output=True, text=True)

    cmd = [
        sys.executable, CYCLE,
        "--baseline", suite,
        "--out", out_path,
        "--quiet",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode not in (0, 1):  # 1 = regression detected, still valid report
        print(f"error: {proc.stderr}", file=sys.stderr)
        return {}
    with open(out_path) as f:
        return json.load(f)


def aggregate(report: dict) -> dict:
    s = report.get("summary", {})
    return {
        "pass": s.get("passed", 0),
        "total": s.get("total", 0),
        "passRate": s.get("passRate", 0.0),
        "routing": s.get("routingAccuracy", 0.0),
        "leak": s.get("leakageRate", 0.0),
        "pivot": s.get("pivotEchoRate", 0.0),
        "misroutes": s.get("misroutes", 0),
        "contam": s.get("contaminations", 0),
        "avgMs": s.get("avgDurationMs", 0),
    }


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--prompt", required=True,
                   help="Prompt id (brain, brain-conversational, soul)")
    p.add_argument("--variants", nargs="+", required=True,
                   help="List of variant names. Empty string = default.")
    p.add_argument("--suite", default=os.path.join(ROOT, "MLTraining", "autonomous-baseline.json"))
    p.add_argument("--runs", type=int, default=1,
                   help="Runs per variant (for variance averaging).")
    p.add_argument("--out-dir", default="/tmp/iclaw-prompt-eval")
    args = p.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    results: dict[str, list[dict]] = {}
    for variant in args.variants:
        # Label the result slot by a short filesystem-safe key. For path
        # variants, use the filename stem (BRAIN.v3-anti-refusal.md →
        # v3-anti-refusal). For bundle variants, use the variant literal.
        if variant and os.path.exists(variant):
            base_no_ext = os.path.splitext(os.path.basename(variant))[0]
            # Strip leading "BRAIN." or similar prefix for brevity
            parts = base_no_ext.split(".", 1)
            key = parts[1] if len(parts) == 2 else base_no_ext
        elif variant:
            key = variant
        else:
            key = "default"
        results[key] = []
        for run in range(args.runs):
            out = os.path.join(args.out_dir, f"{args.prompt}.{key}.run{run}.json")
            print(f"Running {args.prompt}={key} run {run + 1}/{args.runs}...", file=sys.stderr)
            report = run_variant(args.prompt, variant, args.suite, out)
            if report:
                results[key].append(aggregate(report))

    # Averages
    table = []
    for variant, rows in results.items():
        if not rows:
            continue
        avg = {k: sum(r[k] for r in rows) / len(rows) for k in rows[0].keys()}
        table.append((variant, avg, len(rows)))

    print()
    print(f"{'variant':<20} {'pass':>6} {'route%':>8} {'leak%':>8} {'pivot%':>8} {'avgMs':>8}")
    print("-" * 62)
    for variant, avg, n in table:
        print(f"{variant:<20} "
              f"{avg['pass']:>3.1f}/{avg['total']:<3.0f} "
              f"{avg['routing']*100:>7.1f}% "
              f"{avg['leak']*100:>7.1f}% "
              f"{avg['pivot']*100:>7.1f}% "
              f"{avg['avgMs']:>7.0f}   (n={n})")

    # Delta vs first variant
    if len(table) >= 2:
        base_name, base, _ = table[0]
        print()
        print(f"Delta vs {base_name}:")
        for variant, avg, _ in table[1:]:
            dpass = avg["pass"] - base["pass"]
            droute = (avg["routing"] - base["routing"]) * 100
            dleak = (avg["leak"] - base["leak"]) * 100
            dpivot = (avg["pivot"] - base["pivot"]) * 100
            print(f"  {variant:<20} pass {dpass:+.1f}   route {droute:+.2f}pp   leak {dleak:+.2f}pp   pivot {dpivot:+.2f}pp")

    # Reset the UserDefaults variant to default (clear both keys)
    subprocess.run(["defaults", "delete", "NSGlobalDomain", f"prompt.{args.prompt}.variant"],
                   capture_output=True)
    subprocess.run(["defaults", "delete", "NSGlobalDomain", f"prompt.{args.prompt}.variant.path"],
                   capture_output=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
