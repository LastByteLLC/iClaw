#!/usr/bin/env python3
"""Multi-turn probe runner for iClawCLI.

One daemon per SCENARIO (kill/relaunch between scenarios so state is clean
and any hang is isolated). Within a scenario, hangs kill the daemon and
mark remaining turns as 'skipped'.

Usage:
    python3 probe-multiturn.py scenarios.json > results.json
"""
import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path

DAEMON = Path(__file__).resolve().parent.parent / ".build/debug/iClawCLI"
TURN_TIMEOUT = 22.0      # > daemon internal 20s cap by a small margin
COLD_START = 20.0        # first prompt may be slow because of model load
READY_WAIT = 8.0
SHUTDOWN_WAIT = 3.0


def read_line(proc, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return None
    r, _, _ = select.select([proc.stdout], [], [], remaining)
    if not r:
        return None
    line = proc.stdout.readline()
    if not line:
        return None
    return line.strip()


def send(proc, obj):
    payload = json.dumps(obj) + "\n"
    try:
        proc.stdin.write(payload)
        proc.stdin.flush()
    except (BrokenPipeError, OSError):
        pass


def collect_response(proc, deadline):
    strays = []
    while True:
        raw = read_line(proc, deadline)
        if raw is None:
            return None, strays
        if raw == "":
            continue
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            strays.append(raw)
            continue
        mtype = msg.get("type")
        if mtype in ("response", "setting_ack", "status", "error", "ready"):
            return msg, strays
        strays.append(raw)


def launch():
    env = os.environ.copy()
    env["NSUnbufferedIO"] = "YES"
    proc = subprocess.Popen(
        [str(DAEMON)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
        env=env,
    )
    ready, _ = collect_response(proc, time.monotonic() + READY_WAIT)
    if ready is None:
        proc.kill()
        return None
    return proc


def kill(proc):
    if proc and proc.poll() is None:
        try:
            proc.kill()
            proc.wait(timeout=2)
        except Exception:
            pass


def run_scenario(scn):
    proc = launch()
    if proc is None:
        return {"error": "daemon_no_ready_banner"}
    turns_out = []
    try:
        first = True
        for t_idx, prompt in enumerate(scn["turns"]):
            budget = COLD_START if first else TURN_TIMEOUT
            first = False
            send(proc, {"type": "prompt", "text": prompt})
            t0 = time.monotonic()
            msg, strays = collect_response(proc, time.monotonic() + budget)
            wall = time.monotonic() - t0
            if msg is None:
                turns_out.append({
                    "turn": t_idx + 1,
                    "prompt": prompt,
                    "response": None,
                    "timeout": True,
                    "wall_s": round(wall, 2),
                    "strays": strays,
                })
                # Remaining turns are skipped because daemon is presumed wedged
                for r_prompt in scn["turns"][t_idx + 1:]:
                    turns_out.append({
                        "turn": len(turns_out) + 1,
                        "prompt": r_prompt,
                        "skipped": True,
                    })
                break
            turns_out.append({
                "turn": t_idx + 1,
                "prompt": prompt,
                "response": msg.get("text", ""),
                "widget": msg.get("widgetType"),
                "is_error": msg.get("isError") or False,
                "duration_ms": msg.get("durationMs"),
                "wall_s": round(wall, 2),
                "strays": strays,
            })

        # Snapshot daemon state
        send(proc, {"type": "status"})
        status_msg, _ = collect_response(proc, time.monotonic() + 5)
        turn_count = None
        facts = None
        if status_msg is not None:
            turn_count = status_msg.get("turnCount")
            facts = status_msg.get("facts")

        send(proc, {"type": "quit"})
        try:
            proc.wait(timeout=SHUTDOWN_WAIT)
        except subprocess.TimeoutExpired:
            kill(proc)

        return {
            "turns": turns_out,
            "final_turn_count": turn_count,
            "final_facts": facts,
        }
    finally:
        kill(proc)


def main():
    if len(sys.argv) != 2:
        print("usage: probe-multiturn.py scenarios.json", file=sys.stderr)
        sys.exit(2)
    scenarios = json.loads(Path(sys.argv[1]).read_text())
    results = []
    for idx, scn in enumerate(scenarios):
        name = scn["name"]
        print(f"[{idx+1}/{len(scenarios)}] {name}", file=sys.stderr, flush=True)
        t0 = time.monotonic()
        out = run_scenario(scn)
        dur = time.monotonic() - t0
        print(f"    done in {dur:.1f}s", file=sys.stderr, flush=True)
        results.append({
            "scenario": name,
            "category": scn.get("category", ""),
            "expect": scn.get("expect", ""),
            **out,
        })
    json.dump({"results": results}, sys.stdout, indent=2, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
