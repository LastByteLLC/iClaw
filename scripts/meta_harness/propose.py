#!/usr/bin/env python3
"""propose.py — Drive Claude Code (headless) to propose a new harness candidate.

For each iteration:
  1. Figure out the next iter-NNNN index.
  2. Render the skill prompt with the current objective + iter path.
  3. Invoke `claude --print --allowedTools Read,Grep,Glob,Write,Edit` with the
     prompt on stdin, working directory = repo root. Claude reads prior iters,
     writes `candidates/iter-NNNN/harness/` and notes.md.
  4. Run evaluate.py against the new candidate on the search split.
  5. Update candidates/pareto-frontier.json.
  6. Repeat.

The proposer is told NOT to read `candidates/test-set.lock` or any `test/`
traces. Claude Code's allowlist is enforced at the harness level; the prompt
restates the rule for clarity.

Usage:
  python3 Scripts/meta_harness/propose.py \
      --iterations 3 \
      --corpus MLTraining/autonomous-baseline.json \
      [--objective "reduce follow-up false positives"]
"""
from __future__ import annotations
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# HARNESS_ROOT lives OUTSIDE the repo to keep Xcode/sourcekit-lsp's filesystem
# watcher from reindexing on every iter/trace write. Writing thousands of
# files per overnight run inside the watched repo is what ballooned Xcode +
# SourceKit to >100GB swap in the first pilot.
HARNESS_ROOT = Path(
    os.environ.get("HARNESS_ROOT", str(ROOT.parent / "iClaw-candidates"))
).resolve()
CANDIDATES = HARNESS_ROOT
SKILL = Path(__file__).parent / "skill_prompt.md"
EVALUATE = Path(__file__).parent / "evaluate.py"
CLI = ROOT / ".build" / "debug" / "iClawCLI"
CLAUDE = "claude"

DEFAULT_OBJECTIVES = [
    "Reduce routing misroutes — inspect traces/search for prompts where expected tool != routed tool and propose a synonym or keyword fix.",
    "Reduce avg durationMs without dropping passRate by more than 1pp — look for prompts where the conversational path would have sufficed.",
    "Reduce leakage-marker hits in output — tighten BRAIN.md if leaks are present; prompts are in cycle-2-refusals scope.",
]


def next_iter_dir() -> Path:
    existing = sorted(CANDIDATES.glob("iter-*"))
    if not existing:
        return CANDIDATES / "iter-0001"
    last = existing[-1].name
    m = re.match(r"iter-(\d+)$", last)
    n = int(m.group(1)) + 1 if m else len(existing)
    return CANDIDATES / f"iter-{n:04d}"


def read_pareto() -> dict:
    p = CANDIDATES / "pareto-frontier.json"
    if not p.exists():
        return {"frontier": []}
    return json.loads(p.read_text())


def render_prompt(iter_dir: Path, objective: str) -> str:
    tmpl = SKILL.read_text()
    tmpl = tmpl.replace("{OBJECTIVE}", objective)
    # Absolute path — HARNESS_ROOT lives outside the repo, so
    # `.relative_to(ROOT)` would throw. The proposer gets the full path.
    tmpl = tmpl.replace("{ITER_DIR}", str(iter_dir))
    tmpl = tmpl.replace("{HARNESS_ROOT}", str(HARNESS_ROOT))
    return tmpl


def invoke_claude(prompt: str, cwd: Path, timeout_s: int) -> int:
    """Invoke headless Claude Code. Returns exit code.

    Using --print for non-interactive. `--allowedTools` scopes write access
    to what the proposer needs. We stream stdout to the parent so the user
    can see what the agent is doing."""
    cmd = [
        CLAUDE, "--print",
        "--allowedTools", "Read,Grep,Glob,Write,Edit,Bash(ls*),Bash(cat*)",
    ]
    print(f"\n==> claude {' '.join(cmd[1:])}", file=sys.stderr)
    try:
        proc = subprocess.run(
            cmd, input=prompt, cwd=str(cwd), text=True, timeout=timeout_s,
        )
        return proc.returncode
    except subprocess.TimeoutExpired:
        print(f"!! claude call timed out after {timeout_s}s", file=sys.stderr)
        return 124


def run_evaluate(iter_dir: Path, corpora: list[str], split: str = "search",
                 limit: int | None = None) -> dict | None:
    cmd = ["python3", str(EVALUATE), "--iter", str(iter_dir), "--split", split]
    for c in corpora:
        cmd += ["--corpus", c]
    if limit:
        cmd += ["--limit", str(limit)]
    print(f"\n==> {' '.join(cmd)}", file=sys.stderr)
    r = subprocess.run(cmd, cwd=str(ROOT))
    if r.returncode != 0:
        return None
    scores_path = iter_dir / f"scores.{split}.json"
    if not scores_path.exists():
        return None
    return json.loads(scores_path.read_text())


def update_pareto(new_iter: str, scores: dict) -> None:
    """Pareto on (passRate ↑, avgDurationMs ↓). Store non-dominated history."""
    path = CANDIDATES / "pareto-frontier.json"
    pf = read_pareto()
    entry = {
        "iter": new_iter,
        "passRate": scores["aggregate"]["passRate"],
        "avgDurationMs": scores["aggregate"]["avgDurationMs"],
        "passed": scores["aggregate"]["passed"],
        "total": scores["aggregate"]["total"],
    }
    kept = []
    dominated = False
    for e in pf["frontier"]:
        if (e["passRate"] >= entry["passRate"]
                and e["avgDurationMs"] <= entry["avgDurationMs"]
                and (e["passRate"] > entry["passRate"]
                     or e["avgDurationMs"] < entry["avgDurationMs"])):
            dominated = True
        if not (entry["passRate"] >= e["passRate"]
                and entry["avgDurationMs"] <= e["avgDurationMs"]
                and (entry["passRate"] > e["passRate"]
                     or entry["avgDurationMs"] < e["avgDurationMs"])):
            kept.append(e)
    if not dominated:
        kept.append(entry)
    pf["frontier"] = sorted(kept, key=lambda e: -e["passRate"])
    path.write_text(json.dumps(pf, indent=2))
    status = "on frontier" if not dominated else "dominated"
    print(f"\n==> pareto: iter={new_iter} passRate={entry['passRate']:.1%} "
          f"avgMs={entry['avgDurationMs']} — {status}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=1)
    ap.add_argument("--corpus", action="append", required=True)
    ap.add_argument("--objective", default=None,
                    help="override rotating objective; if omitted, rotates through defaults")
    ap.add_argument("--claude-timeout", type=int, default=900,
                    help="seconds to allow claude --print per iteration")
    ap.add_argument("--limit", type=int, default=None,
                    help="pass --limit N to the evaluator (smoke mode)")
    args = ap.parse_args()

    CANDIDATES.mkdir(parents=True, exist_ok=True)
    baseline_harness = CANDIDATES / "iter-0000" / "harness"
    print(f"HARNESS_ROOT = {CANDIDATES}", file=sys.stderr)
    for i in range(args.iterations):
        # Sweep any stale iClawCLI processes left behind by a previous
        # iteration (failed kill(), orphaned by a SIGKILL of the evaluator,
        # etc.). Each live daemon pins ~2-4GB (Foundation Model loaded) —
        # without this sweep they accumulate across iterations.
        try:
            subprocess.run(["pkill", "-9", "-f", str(CLI)], check=False,
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except Exception as e:
            print(f"  (pkill sweep failed: {e})", file=sys.stderr)
        iter_dir = next_iter_dir()
        iter_dir.mkdir(parents=True, exist_ok=True)
        new_harness = iter_dir / "harness"
        new_harness.mkdir(exist_ok=True)
        # Seed the new iter with the baseline snapshot so the proposer doesn't
        # need to `cp` manually — it just edits the specific files it cares
        # about. ConfigLoader's overlay falls through to bundle for files the
        # proposer deletes.
        if baseline_harness.is_dir() and not any(new_harness.iterdir()):
            for src in baseline_harness.iterdir():
                if src.is_file():
                    (new_harness / src.name).write_bytes(src.read_bytes())
        objective = args.objective or DEFAULT_OBJECTIVES[i % len(DEFAULT_OBJECTIVES)]
        prompt = render_prompt(iter_dir, objective)

        print(f"\n============================================================", file=sys.stderr)
        print(f"  iteration {i + 1}/{args.iterations} — {iter_dir.name}", file=sys.stderr)
        print(f"  objective: {objective}", file=sys.stderr)
        print(f"============================================================", file=sys.stderr)

        # Hash the seeded harness so we can detect whether the proposer
        # actually changed anything. A proposer that writes a file identical
        # to the baseline (or never writes anything beyond the seed) should
        # be noted but not re-evaluated — re-running iter-0000's baseline
        # burns ~13 minutes for zero signal.
        import hashlib
        def harness_hash(p: Path) -> str:
            h = hashlib.sha256()
            for f in sorted(p.glob("*")):
                if f.is_file():
                    h.update(f.name.encode())
                    h.update(f.read_bytes())
            return h.hexdigest()
        pre_hash = harness_hash(iter_dir / "harness")

        rc = invoke_claude(prompt, cwd=ROOT, timeout_s=args.claude_timeout)
        if rc != 0:
            print(f"!! claude returned {rc} — skipping eval", file=sys.stderr)
            continue
        if not any((iter_dir / "harness").iterdir()):
            print(f"!! {iter_dir}/harness is empty — proposer wrote nothing", file=sys.stderr)
            continue
        post_hash = harness_hash(iter_dir / "harness")
        if pre_hash == post_hash:
            print(f"!! proposer made no effective changes to {iter_dir.name}/harness — skipping eval", file=sys.stderr)
            # Leave an empty scores marker so the monitor sees this iter
            (iter_dir / "scores.search.json").write_text(json.dumps({
                "iter": iter_dir.name, "split": "search",
                "aborted": True, "reason": "no_change",
                "aggregate": {"total": 0, "passed": 0, "passRate": 0.0,
                              "avgDurationMs": 0}
            }, indent=2))
            continue
        scores = run_evaluate(iter_dir, args.corpus, split="search", limit=args.limit)
        if scores is None:
            print(f"!! evaluate failed for {iter_dir.name}", file=sys.stderr)
            continue
        update_pareto(iter_dir.name, scores)
    return 0


if __name__ == "__main__":
    sys.exit(main())
