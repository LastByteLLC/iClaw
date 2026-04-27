#!/usr/bin/env python3
"""evaluate.py — Score one harness candidate against a prompt corpus.

Meta-Harness evaluator. Spawns `iClawCLI --harness-dir <harness> --trace-dir
<iter>/traces/<split>` and runs each prompt, applies deterministic grading
(expectedTools, mustContain/mustNotContain, leakage markers, maxMs), and
writes `<iter>/scores.json`.

Usage:
  python3 Scripts/meta_harness/evaluate.py \
      --iter candidates/iter-0000 \
      --corpus MLTraining/autonomous-baseline.json \
      [--corpus MLTraining/cycle-probes/cycle-2-refusals.json ...] \
      [--split search|test]

Exit codes:
  0 — evaluation completed (inspect scores.json for pass/fail)
  2 — infrastructure failure (daemon crashed, corpus missing, build missing)
"""
from __future__ import annotations
import argparse
import json
import os
import select
import signal
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / ".build" / "debug" / "iClawCLI"
READ_TIMEOUT = 30.0
STARTUP_TIMEOUT = 120.0
MAX_DAEMON_RESTARTS = 3
RESTART_BACKOFF_SECONDS = (5, 15, 45)
WALL_CLOCK_BUDGET_SECONDS = float(os.environ.get("EVAL_WALL_CLOCK_S", "1800"))


class Daemon:
    def __init__(self, harness_dir: Path, trace_dir: Path, real_tools: bool = False):
        self.harness_dir = harness_dir
        self.trace_dir = trace_dir
        self.real_tools = real_tools
        self.proc: subprocess.Popen | None = None

    def start(self) -> None:
        if not CLI.exists():
            raise FileNotFoundError(f"{CLI} — run `make cli` first")
        self.trace_dir.mkdir(parents=True, exist_ok=True)
        args = [str(CLI),
                "--harness-dir", str(self.harness_dir),
                "--trace-dir", str(self.trace_dir)]
        if self.real_tools:
            args.append("--real-tools")
        # start_new_session=True puts the daemon in its own process group so
        # we can SIGKILL the entire tree (daemon + any XPC helpers it spawns).
        # Without this, a runaway daemon's descendants orphan when evaluator
        # exits.
        self.proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
            start_new_session=True,
        )
        ready = self._recv(timeout=STARTUP_TIMEOUT)
        if not ready or ready.get("type") != "ready":
            raise RuntimeError(f"daemon did not emit ready: {ready}")

    def kill(self) -> None:
        if self.proc and self.proc.poll() is None:
            # Graceful quit lets the daemon flush any pending trace writes.
            try:
                if self.proc.stdin and not self.proc.stdin.closed:
                    self.proc.stdin.write(json.dumps({"type": "quit"}) + "\n")
                    self.proc.stdin.flush()
            except Exception: pass
            try: self.proc.wait(timeout=5)
            except Exception:
                # Group-signal the whole session — daemon + any children
                # it forked (Foundation Models XPC, etc.). Fall through to
                # plain .kill() if the group signal raises.
                try:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
                except Exception:
                    try: self.proc.terminate()
                    except Exception: pass
                try: self.proc.wait(timeout=3)
                except Exception:
                    try:
                        os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
                    except Exception:
                        try: self.proc.kill()
                        except Exception: pass
                    try: self.proc.wait(timeout=3)
                    except Exception: pass
        self.proc = None

    def prompt(self, text: str, timeout: float = READ_TIMEOUT) -> dict | None:
        assert self.proc and self.proc.stdin
        # Daemon may have exited between prior `_recv` and this call. Detect
        # early so the eval loop treats it as "no response" and restarts,
        # rather than raising BrokenPipeError out of the writer.
        if self.proc.poll() is not None:
            return None
        try:
            self.proc.stdin.write(json.dumps({"type": "prompt", "text": text}) + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            return None
        return self._recv(timeout)

    def reset(self) -> None:
        assert self.proc and self.proc.stdin
        self.proc.stdin.write(json.dumps({"type": "reset"}) + "\n")
        self.proc.stdin.flush()
        self._recv(timeout=10)

    def _recv(self, timeout: float) -> dict | None:
        assert self.proc and self.proc.stdout
        rlist, _, _ = select.select([self.proc.stdout.fileno()], [], [], timeout)
        if not rlist: return None
        line = self.proc.stdout.readline()
        if not line: return None
        try: return json.loads(line.strip())
        except Exception as e: return {"type": "error", "message": f"parse: {e!r}"}


def grade_one(entry: dict, result: dict | None,
              markers_by_corpus: dict[str, list[str]]) -> dict:
    """Grade a single prompt result. Mirrors autonomous_cycle.py::evaluate.
    Leakage markers are applied PER-CORPUS — the prompt is only checked
    against its own corpus's markers, not globally. This prevents
    `[stubbed]` (a marker in R2-contacts that means "contact-stub leak")
    from false-flagging every email/contact prompt across all probes."""
    text = (result.get("text") or result.get("message") or "") if result else ""
    routed = (result or {}).get("routedTools") or []
    outcome = (result or {}).get("routingOutcome") or ""
    dur = (result or {}).get("durationMs") or 0
    failures: list[str] = []

    if not result:
        failures.append("timeout:no_response")
    elif result.get("isError") is True:
        failures.append("isError:true")

    expected = entry.get("expectedTools") or []
    if expected and not any(t in routed for t in expected):
        failures.append(f"routing:expected={expected} got={routed or outcome}")

    for s in entry.get("mustContain") or []:
        if s.lower() not in text.lower():
            failures.append(f"missing:{s!r}")
    for s in entry.get("mustNotContain") or []:
        if s.lower() in text.lower():
            failures.append(f"contamination:{s!r}")
    corpus_markers = markers_by_corpus.get(entry.get("_corpus", ""), [])
    for m in corpus_markers:
        if m in text:
            failures.append(f"leak:{m!r}")

    max_ms = entry.get("maxMs")
    if max_ms and dur > max_ms:
        failures.append(f"slow:{dur}ms>{max_ms}ms")

    return {
        "id": entry["id"],
        "prompt": entry["text"],
        "category": entry.get("category", "?"),
        "corpus": entry.get("_corpus", "?"),
        "passed": len(failures) == 0,
        "failures": failures,
        "durationMs": dur,
        "routedTools": routed,
        "routingOutcome": outcome,
    }


def aggregate(results: list[dict]) -> dict:
    total = len(results)
    if total == 0:
        return {"total": 0, "passRate": 0.0}
    passed = sum(1 for r in results if r["passed"])
    misroutes = sum(1 for r in results if any(f.startswith("routing:") for f in r["failures"]))
    leaks = sum(1 for r in results if any(f.startswith("leak:") for f in r["failures"]))
    timeouts = sum(1 for r in results if any("timeout" in f for f in r["failures"]))
    contam = sum(1 for r in results if any(f.startswith("contamination:") for f in r["failures"]))
    avg_ms = sum(r["durationMs"] for r in results) / total
    total_ms = sum(r["durationMs"] for r in results)

    by_cat: dict[str, dict] = defaultdict(lambda: {"total": 0, "passed": 0})
    for r in results:
        c = r["category"]
        by_cat[c]["total"] += 1
        if r["passed"]: by_cat[c]["passed"] += 1

    return {
        "total": total,
        "passed": passed,
        "passRate": round(passed / total, 4),
        "misroutes": misroutes,
        "leaks": leaks,
        "timeouts": timeouts,
        "contaminations": contam,
        "avgDurationMs": round(avg_ms, 0),
        "totalDurationMs": total_ms,
        "byCategory": {k: {**v, "passRate": round(v["passed"] / v["total"], 4)} for k, v in by_cat.items()},
    }


def load_corpus(paths: list[Path]) -> tuple[list[dict], dict[str, list[str]]]:
    """Load prompts from multiple corpus files; return the flat prompt list
    plus a per-corpus leakage-markers map (keyed by corpus stem)."""
    prompts: list[dict] = []
    markers_by_corpus: dict[str, list[str]] = {}
    for p in paths:
        with open(p) as f:
            spec = json.load(f)
        for e in spec.get("prompts", []):
            e["_corpus"] = p.stem
            prompts.append(e)
        markers_by_corpus[p.stem] = spec.get("leakageMarkers", [])
    return prompts, markers_by_corpus


def apply_split(prompts: list[dict], split: str | None, lock_path: Path | None) -> list[dict]:
    """If a test-set.lock file is present and split is specified, filter prompts
    to match the split. Otherwise return all prompts."""
    if not split or not lock_path or not lock_path.exists():
        return prompts
    with open(lock_path) as f:
        lock = json.load(f)
    test_ids = set(lock.get("test", []))
    if split == "test":
        return [p for p in prompts if p["id"] in test_ids]
    if split == "search":
        return [p for p in prompts if p["id"] not in test_ids]
    return prompts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iter", required=True, help="iteration dir (e.g. candidates/iter-0001)")
    ap.add_argument("--corpus", action="append", required=True,
                    help="path to a prompt corpus JSON (repeatable)")
    ap.add_argument("--split", choices=["search", "test"], default="search",
                    help="which side of the held-out split to score (default: search)")
    default_lock = str(Path(os.environ.get(
        "HARNESS_ROOT", str(ROOT.parent / "iClaw-candidates")
    )) / "test-set.lock")
    ap.add_argument("--lock", default=default_lock,
                    help="test-set lock file from split_corpus.py")
    ap.add_argument("--real-tools", action="store_true")
    ap.add_argument("--limit", type=int, default=None,
                    help="score only the first N prompts (smoke test)")
    args = ap.parse_args()

    iter_dir = Path(args.iter).resolve()
    harness_dir = iter_dir / "harness"
    if not harness_dir.is_dir():
        print(f"error: {harness_dir} is not a directory", file=sys.stderr)
        return 2

    # Pre-flight: every *.json in the harness must parse. A malformed file
    # silently falls through to the bundled default (ConfigLoader logs an
    # error but returns nil) — or worse, causes a runtime decode failure.
    # Catch it here so the proposer gets a clear signal.
    json_errors: list[str] = []
    for jf in harness_dir.glob("*.json"):
        try:
            json.loads(jf.read_text())
        except Exception as e:
            json_errors.append(f"{jf.name}: {e}")
    if json_errors:
        print(f"error: harness has malformed JSON:", file=sys.stderr)
        for e in json_errors:
            print(f"  {e}", file=sys.stderr)
        # Still write a scores file so the pilot records the regression
        # rather than silently skipping.
        out = iter_dir / f"scores.{args.split}.json"
        with open(out, "w") as f:
            json.dump({
                "iter": iter_dir.name, "split": args.split,
                "aborted": True, "reason": "malformed_json",
                "jsonErrors": json_errors,
                "aggregate": {"total": 0, "passed": 0, "passRate": 0.0,
                              "avgDurationMs": 0, "misroutes": 0, "leaks": 0,
                              "timeouts": 0, "contaminations": 0,
                              "byCategory": {}},
                "perPrompt": [],
            }, f, indent=2)
        return 2

    trace_dir = iter_dir / "traces" / args.split
    prompts, markers = load_corpus([Path(p) for p in args.corpus])
    prompts = apply_split(prompts, args.split, Path(args.lock))
    if args.limit:
        prompts = prompts[:args.limit]
    if not prompts:
        print("error: no prompts after split/limit", file=sys.stderr)
        return 2

    print(f"evaluating {len(prompts)} prompts against {harness_dir.name} ({args.split})",
          file=sys.stderr)

    d = Daemon(harness_dir=harness_dir, trace_dir=trace_dir, real_tools=args.real_tools)
    try:
        d.start()
    except Exception as e:
        print(f"daemon start failed: {e}", file=sys.stderr)
        return 2

    results: list[dict] = []
    consecutive_timeouts = 0
    restart_count = 0
    aborted_reason: str | None = None
    t0 = time.time()
    current_corpus = None
    try:
        for i, entry in enumerate(prompts, 1):
            # Wall-clock budget: one pathological iteration must not consume
            # the entire overnight window. Write an aborted scores file so
            # the proposer sees the regression, not a silent skip.
            if time.time() - t0 > WALL_CLOCK_BUDGET_SECONDS:
                aborted_reason = "wall_clock"
                print(f"  !! wall-clock budget exceeded "
                      f"({WALL_CLOCK_BUDGET_SECONDS:.0f}s) — aborting eval",
                      file=sys.stderr)
                break

            # Reset conversation state when crossing corpus boundaries.
            # Within a corpus (e.g., cycle-10-memory) state persists so
            # multi-turn tests work; across corpora a clean slate prevents
            # pollution (e.g., Austin/Boston memory bleeding into the
            # multilingual probe).
            if entry["_corpus"] != current_corpus:
                if current_corpus is not None:
                    d.reset()
                current_corpus = entry["_corpus"]
            r = d.prompt(entry["text"])
            g = grade_one(entry, r, markers)
            results.append(g)
            status = "✓" if g["passed"] else "✗"
            print(f"  [{i:3d}/{len(prompts)}] {status} {entry['id']:<32} "
                  f"{g['durationMs']:>5}ms  {','.join(g['failures'][:1])}",
                  file=sys.stderr)

            # Daemon-hang recovery: 3 consecutive full timeouts means the
            # daemon is wedged. Kill it, back off, respawn. If respawns also
            # fail (or we hit MAX_DAEMON_RESTARTS), abort the eval — don't
            # spin forever spawning daemons under memory pressure, which is
            # what crashed the host last time. Failures stay on record.
            if r is None:
                consecutive_timeouts += 1
                if consecutive_timeouts >= 3:
                    if restart_count >= MAX_DAEMON_RESTARTS:
                        aborted_reason = "daemon_hang_max_restarts"
                        print(f"  !! {MAX_DAEMON_RESTARTS} daemon restarts "
                              f"exhausted — aborting eval", file=sys.stderr)
                        break
                    backoff = RESTART_BACKOFF_SECONDS[
                        min(restart_count, len(RESTART_BACKOFF_SECONDS) - 1)
                    ]
                    print(f"  !! 3 consecutive timeouts — restart "
                          f"{restart_count + 1}/{MAX_DAEMON_RESTARTS} after "
                          f"{backoff}s backoff", file=sys.stderr)
                    d.kill()
                    time.sleep(backoff)
                    d = Daemon(harness_dir=harness_dir, trace_dir=trace_dir,
                               real_tools=args.real_tools)
                    try:
                        d.start()
                        consecutive_timeouts = 0
                        restart_count += 1
                    except Exception as e:
                        print(f"  !! daemon restart failed: {e}",
                              file=sys.stderr)
                        aborted_reason = "daemon_restart_failed"
                        break
            else:
                consecutive_timeouts = 0
    finally:
        d.kill()

    wall = round(time.time() - t0, 1)
    agg = aggregate(results)
    scores: dict[str, Any] = {
        "iter": iter_dir.name,
        "split": args.split,
        "corpora": [Path(p).name for p in args.corpus],
        "promptCount": len(prompts),
        "wallSeconds": wall,
        "aggregate": agg,
        "perPrompt": results,
    }
    if aborted_reason:
        scores["aborted"] = True
        scores["reason"] = aborted_reason
        scores["restartCount"] = restart_count
    out = iter_dir / f"scores.{args.split}.json"
    with open(out, "w") as f:
        json.dump(scores, f, indent=2)
    if aborted_reason:
        print(f"\naborted ({aborted_reason}) — "
              f"{agg['passed']}/{agg['total']} graded before abort, "
              f"wrote {out}", file=sys.stderr)
        return 2
    print(f"\n{agg['passed']}/{agg['total']} passed "
          f"({agg['passRate']:.1%}) — wrote {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
