#!/usr/bin/env python3
"""autonomous_cycle.py — End-to-end test-and-score cycle for iClaw.

Spawns iClawCLI, runs each prompt in `MLTraining/autonomous-baseline.json`,
applies deterministic guards (expected tools, must/mustNot substrings,
leakage markers, duration), and emits a regression report.

Exit code:
  0 — all thresholds met
  1 — one or more threshold violations (regression)
  2 — infrastructure failure (CLI crashed, baseline missing, etc.)

Usage:
  python3 Scripts/autonomous_cycle.py
  python3 Scripts/autonomous_cycle.py --json       # emit full JSON report
  python3 Scripts/autonomous_cycle.py --out PATH   # write report to PATH

The daemon is run with `--real-tools` only if `--real-tools` is passed to
this script; otherwise headless stubs handle all EventKit / AppleScript
paths. ConsentManager is preset to `alwaysApprove`.
"""
from __future__ import annotations
import argparse
import json
import os
import select
import subprocess
import sys
import time
from collections import defaultdict
from typing import Any

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, ".build", "debug", "iClawCLI")
BASELINE = os.path.join(ROOT, "MLTraining", "autonomous-baseline.json")
READ_TIMEOUT = 30.0

# ----- colors (only when stdout is a terminal) -----
_T = sys.stdout.isatty()
def _c(code): return f"\033[{code}m" if _T else ""
RED, GREEN, YELLOW, CYAN, DIM, RESET = _c(31), _c(32), _c(33), _c(36), _c(2), _c(0)

# ----- daemon wrapper -----

class Daemon:
    def __init__(self, binary: str = CLI, real_tools: bool = False):
        self.binary = binary
        self.real_tools = real_tools
        self.proc: subprocess.Popen | None = None

    def start(self) -> None:
        if not os.path.exists(self.binary):
            raise FileNotFoundError(f"{self.binary} not found — run `make cli` first")
        args = [self.binary]
        if self.real_tools:
            args.append("--real-tools")
        self.proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        r = self._recv(timeout=120)
        if not r or r.get("type") != "ready":
            raise RuntimeError(f"daemon did not emit ready: {r}")

    def kill(self) -> None:
        if self.proc and self.proc.poll() is None:
            try: self.proc.kill()
            except Exception: pass
            try: self.proc.wait(timeout=3)
            except Exception: pass
        self.proc = None

    def send(self, cmd: dict[str, Any]) -> None:
        assert self.proc and self.proc.stdin
        self.proc.stdin.write(json.dumps(cmd) + "\n")
        self.proc.stdin.flush()

    def _recv(self, timeout: float) -> dict | None:
        assert self.proc and self.proc.stdout
        fd = self.proc.stdout.fileno()
        rlist, _, _ = select.select([fd], [], [], timeout)
        if not rlist: return None
        line = self.proc.stdout.readline()
        if not line: return None
        try: return json.loads(line.strip())
        except Exception as e: return {"type": "error", "message": f"parse: {e!r}"}

    def prompt(self, text: str, timeout: float = READ_TIMEOUT) -> dict | None:
        self.send({"type": "prompt", "text": text})
        return self._recv(timeout)

    def reset(self) -> dict | None:
        self.send({"type": "reset"})
        return self._recv(timeout=10)

# ----- scoring -----

def evaluate(entry: dict, result: dict, leakage_markers: list[str]) -> dict:
    """Apply deterministic guards to a single prompt result."""
    text = (result.get("text") or result.get("message") or "") if result else ""
    routed = (result or {}).get("routedTools") or []
    outcome = (result or {}).get("routingOutcome") or ""
    dur = (result or {}).get("durationMs") or (result or {}).get("_wallMs") or 0

    failures: list[str] = []

    # CLI hang
    if not result or result.get("_hang"):
        failures.append("timeout:no_response_in_30s")

    # isError
    if result and result.get("isError") is True:
        failures.append("isError:true")

    # Expected tools
    expected = entry.get("expectedTools") or []
    if expected:
        hit = any(t in routed for t in expected)
        if not hit:
            failures.append(f"routing:expected=[{','.join(expected)}] got=[{','.join(routed) or outcome}]")

    # Must-contain
    for s in entry.get("mustContain") or []:
        if s.lower() not in text.lower():
            failures.append(f"missing:{s!r}")

    # Must-not-contain (explicit per-prompt)
    for s in entry.get("mustNotContain") or []:
        if s.lower() in text.lower():
            failures.append(f"contamination:{s!r}")

    # Global leakage markers
    for m in leakage_markers:
        if m in text:
            failures.append(f"leak:{m!r}")

    # Widget type
    expected_widget = entry.get("expectedWidget")
    actual_widget = (result or {}).get("widgetType")
    if expected_widget:
        if not actual_widget:
            failures.append(f"widget:expected={expected_widget} got=none")
        elif expected_widget.lower() not in actual_widget.lower() and actual_widget.lower() not in expected_widget.lower():
            failures.append(f"widget:expected={expected_widget} got={actual_widget}")

    # Duration
    max_ms = entry.get("maxMs")
    if max_ms and dur > max_ms:
        failures.append(f"slow:{dur}ms>{max_ms}ms")

    return {
        "id": entry["id"],
        "prompt": entry["text"],
        "category": entry.get("category", "?"),
        "text": text,
        "routedTools": routed,
        "routingOutcome": outcome,
        "pivotDetected": (result or {}).get("pivotDetected"),
        "followUpDetected": (result or {}).get("followUpDetected"),
        "durationMs": dur,
        "passed": len(failures) == 0,
        "failures": failures,
    }


def aggregate(results: list[dict], thresholds: dict) -> dict:
    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    timeouts = sum(1 for r in results if any("timeout" in f for f in r["failures"]))
    leaks = sum(1 for r in results if any(f.startswith("leak:") for f in r["failures"]))
    misroutes = sum(1 for r in results if any(f.startswith("routing:") for f in r["failures"]))
    contam = sum(1 for r in results if any(f.startswith("contamination:") for f in r["failures"]))
    avg_ms = (sum(r["durationMs"] for r in results) / total) if total else 0

    routing_accuracy = 1.0 - misroutes / total if total else 0.0
    leakage_rate = leaks / total if total else 0.0
    timeout_rate = timeouts / total if total else 0.0
    pivot_echo_rate = contam / total if total else 0.0   # contamination implies pivot-echo in our baseline

    by_cat: dict[str, dict] = defaultdict(lambda: {"total": 0, "passed": 0})
    for r in results:
        c = r["category"]
        by_cat[c]["total"] += 1
        if r["passed"]: by_cat[c]["passed"] += 1

    regressions = []
    if routing_accuracy < thresholds.get("routingAccuracy", 0.80):
        regressions.append(f"routingAccuracy {routing_accuracy:.2%} < {thresholds['routingAccuracy']:.2%}")
    if leakage_rate > thresholds.get("leakageRate", 0.0):
        regressions.append(f"leakageRate {leakage_rate:.2%} > {thresholds['leakageRate']:.2%}")
    if pivot_echo_rate > thresholds.get("pivotEchoRate", 0.0):
        regressions.append(f"pivotEchoRate {pivot_echo_rate:.2%} > {thresholds['pivotEchoRate']:.2%}")
    if timeout_rate > thresholds.get("timeoutRate", 0.02):
        regressions.append(f"timeoutRate {timeout_rate:.2%} > {thresholds['timeoutRate']:.2%}")
    if avg_ms > thresholds.get("maxAvgDurationMs", 8000):
        regressions.append(f"avgDurationMs {avg_ms:.0f} > {thresholds['maxAvgDurationMs']}")

    return {
        "total": total,
        "passed": passed,
        "passRate": passed / total if total else 0.0,
        "timeouts": timeouts,
        "leaks": leaks,
        "misroutes": misroutes,
        "contaminations": contam,
        "avgDurationMs": round(avg_ms, 0),
        "routingAccuracy": round(routing_accuracy, 4),
        "leakageRate": round(leakage_rate, 4),
        "timeoutRate": round(timeout_rate, 4),
        "pivotEchoRate": round(pivot_echo_rate, 4),
        "byCategory": dict(by_cat),
        "regressions": regressions,
    }

# ----- main -----

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--baseline", default=BASELINE)
    p.add_argument("--json", action="store_true", help="emit full JSON report to stdout")
    p.add_argument("--out", default=None, help="also write the JSON report to this path")
    p.add_argument("--real-tools", action="store_true", help="disable headless stubs")
    p.add_argument("--quiet", action="store_true", help="suppress per-prompt progress lines")
    p.add_argument("--runs", type=int, default=1,
                   help="Runs per prompt for variance measurement (≥2 enables routing-agreement + edit-distance metrics).")
    args = p.parse_args()

    try:
        with open(args.baseline) as f:
            spec = json.load(f)
    except FileNotFoundError:
        print(f"{RED}baseline not found: {args.baseline}{RESET}", file=sys.stderr)
        return 2

    leakage_markers = spec.get("leakageMarkers", [])
    thresholds = spec.get("thresholds", {})
    prompts = spec.get("prompts", [])

    print(f"{CYAN}iClaw autonomous cycle — {len(prompts)} prompts — baseline {spec.get('version', '?')}{RESET}", file=sys.stderr)
    print(f"{DIM}thresholds: {thresholds}{RESET}", file=sys.stderr)

    daemon = Daemon(real_tools=args.real_tools)
    try:
        daemon.start()
    except Exception as e:
        print(f"{RED}daemon failed to start: {e}{RESET}", file=sys.stderr)
        return 2

    results: list[dict] = []
    t_total = time.time()
    try:
        for i, entry in enumerate(prompts, 1):
            t0 = time.time()
            # Multi-run variance: execute the prompt N times; keep the MAJORITY
            # routing outcome; compute edit-distance across response texts.
            multi_results: list[dict] = []
            for _ in range(max(args.runs, 1)):
                r_one = daemon.prompt(entry["text"])
                if r_one is not None:
                    multi_results.append(r_one)
                if args.runs > 1:
                    # Reset between runs so prior-turn ctx doesn't bias.
                    daemon.reset()
            r = multi_results[0] if multi_results else None
            if r is not None and args.runs > 1:
                # Attach variance fields to the primary result dict.
                routed = [tuple(sorted(x.get("routedTools") or [])) for x in multi_results]
                agree = sum(1 for x in routed if x == routed[0]) / len(routed)
                texts = [x.get("text") or "" for x in multi_results]
                # Simple edit-distance proxy: token-set Jaccard divergence (1 - similarity).
                sets = [set(t.lower().split()) for t in texts]
                sims: list[float] = []
                for a in range(len(sets)):
                    for b in range(a + 1, len(sets)):
                        u = sets[a] | sets[b]
                        inter = sets[a] & sets[b]
                        sims.append(len(inter) / len(u) if u else 1.0)
                mean_sim = sum(sims) / len(sims) if sims else 1.0
                r["_routingAgreement"] = round(agree, 3)
                r["_responseSimilarity"] = round(mean_sim, 3)
                r["_nRuns"] = len(multi_results)
            wall = int((time.time() - t0) * 1000)

            if r is None:
                # Hard hang — restart and continue
                r = {"type": "error", "message": "CLI_HANG", "_hang": True, "durationMs": wall}
                daemon.kill()
                try: daemon.start()
                except Exception as ex:
                    print(f"{RED}daemon restart failed: {ex}{RESET}", file=sys.stderr)
                    break

            if "durationMs" not in r: r["durationMs"] = wall

            evaluated = evaluate(entry, r, leakage_markers)
            results.append(evaluated)

            if not args.quiet:
                mark = f"{GREEN}PASS{RESET}" if evaluated["passed"] else f"{RED}FAIL{RESET}"
                routed = ",".join(evaluated["routedTools"]) or evaluated["routingOutcome"] or "-"
                line = f"[{i:02}/{len(prompts)}] {mark} {evaluated['durationMs']:>5}ms  {entry['id']:<24} tool={routed:<22}"
                if evaluated["failures"]:
                    line += f"  {YELLOW}{' | '.join(evaluated['failures'])}{RESET}"
                print(line, file=sys.stderr, flush=True)

            # Reset between categories to keep conversation state clean across
            # unrelated prompts. Within-category follow-ups would skip this.
            if i < len(prompts) and prompts[i]["category"] != entry["category"]:
                daemon.reset()

    finally:
        daemon.kill()

    agg = aggregate(results, thresholds)
    elapsed = int((time.time() - t_total))

    print("", file=sys.stderr)
    print(f"{CYAN}=== Summary ({elapsed}s total) ==={RESET}", file=sys.stderr)
    print(f"  pass: {agg['passed']}/{agg['total']} ({agg['passRate']:.1%})", file=sys.stderr)
    print(f"  routingAccuracy: {agg['routingAccuracy']:.2%}", file=sys.stderr)
    print(f"  leakageRate: {agg['leakageRate']:.2%}    pivotEchoRate: {agg['pivotEchoRate']:.2%}", file=sys.stderr)
    print(f"  timeouts: {agg['timeouts']}   misroutes: {agg['misroutes']}   leaks: {agg['leaks']}   contam: {agg['contaminations']}", file=sys.stderr)
    print(f"  avgDurationMs: {agg['avgDurationMs']:.0f}", file=sys.stderr)
    for cat, v in sorted(agg["byCategory"].items()):
        print(f"    {cat:<12} {v['passed']}/{v['total']}", file=sys.stderr)

    report = {
        "version": spec.get("version"),
        "elapsedSec": elapsed,
        "summary": agg,
        "results": results,
    }
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, indent=2)
        print(f"{DIM}report written to {args.out}{RESET}", file=sys.stderr)
    if args.json:
        print(json.dumps(report, indent=2))

    if agg["regressions"]:
        print(f"\n{RED}REGRESSION — {len(agg['regressions'])} threshold violation(s):{RESET}", file=sys.stderr)
        for reg in agg["regressions"]:
            print(f"  - {reg}", file=sys.stderr)
        return 1
    print(f"\n{GREEN}OK — all thresholds met{RESET}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
