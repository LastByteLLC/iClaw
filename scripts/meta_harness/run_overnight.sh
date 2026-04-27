#!/usr/bin/env bash
# run_overnight.sh — Kick off a long meta-harness pilot run, safely.
#
# Usage: Scripts/meta_harness/run_overnight.sh [iterations]
# Default iterations = 15. Each iteration: claude proposer (~3-5 min) + full
# corpus eval (~13 min). 15 iters ≈ 4-5 hours.
#
# Env overrides:
#   HARNESS_ROOT=/path        — candidate/trace dir (default ../iClaw-candidates)
#   SWAP_ABORT_MB=40000       — kill the run if swap exceeds this (default 40GB)
#   FORCE=1                   — skip Xcode/LSP/swap pre-flight checks
#
# Safety features retrofitted after the overnight pilot crashed the host:
#   - Refuses to run while Xcode or sourcekit-lsp is attached to this repo.
#   - Refuses to run if swap is already non-trivial at start.
#   - Background sentinel aborts the whole group if swap crosses the threshold.
#   - HARNESS_ROOT points outside the repo so writes don't churn SourceKit.

set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_ROOT="$(pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"
ITERS="${1:-15}"
SWAP_ABORT_MB="${SWAP_ABORT_MB:-40000}"
export HARNESS_ROOT="${HARNESS_ROOT:-$(cd .. && pwd)/iClaw-candidates}"

# ---------- pre-flight ----------
if [[ "${FORCE:-}" != "1" ]]; then
  # Xcode or sourcekit-lsp attached to this repo = reindex-on-every-write,
  # which is the exact scenario that ran memory to >100GB last time.
  if pgrep -af "Xcode" | grep -q "$REPO_NAME" 2>/dev/null; then
    echo "!! Xcode appears attached to $REPO_NAME. Close it or set FORCE=1." >&2
    exit 1
  fi
  if pgrep -af "sourcekit-lsp" | grep -q "$REPO_ROOT" 2>/dev/null; then
    echo "!! sourcekit-lsp appears attached to $REPO_ROOT. Close editors or set FORCE=1." >&2
    exit 1
  fi
  # Any Xcode at all + iClaw.xcodeproj existing is enough to suspect watching.
  if pgrep -q "^Xcode$" 2>/dev/null && [[ -d "$REPO_ROOT/iClaw.xcodeproj" ]]; then
    echo "!! Xcode is running and iClaw.xcodeproj exists. Quit Xcode or set FORCE=1." >&2
    exit 1
  fi
  # Abort on pre-existing swap pressure — we need headroom.
  swap_used_mb=$(sysctl -n vm.swapusage | awk '{for(i=1;i<=NF;i++) if($i=="used"){gsub(/[^0-9.]/,"",$(i+2)); print int($(i+2)); exit}}')
  if [[ -n "${swap_used_mb:-}" ]] && (( swap_used_mb > 2000 )); then
    echo "!! swap already at ${swap_used_mb}MB — bring it down or set FORCE=1." >&2
    exit 1
  fi
fi

mkdir -p "$HARNESS_ROOT"
echo "==> HARNESS_ROOT=$HARNESS_ROOT  ITERS=$ITERS  SWAP_ABORT_MB=$SWAP_ABORT_MB"

# ---------- memory sentinel ----------
# Poll swap every 30s. If it crosses the threshold, group-kill the session.
# Writes a breadcrumb so the user knows what happened on wake-up.
SENTINEL_LOG="$HARNESS_ROOT/sentinel.log"
SESSION_PGID=$$
(
  while true; do
    used_mb=$(sysctl -n vm.swapusage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){gsub(/[^0-9.]/,"",$(i+2)); print int($(i+2)); exit}}')
    if [[ -n "${used_mb:-}" ]] && (( used_mb > SWAP_ABORT_MB )); then
      ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      echo "[$ts] ABORT — swap=${used_mb}MB > ${SWAP_ABORT_MB}MB threshold" >> "$SENTINEL_LOG"
      # Group kill: propose.py, its evaluate.py child, any iClawCLI daemons
      # (thanks to start_new_session=True they're in their own pgid, which is
      # why we also sweep by name as a belt-and-suspenders).
      pkill -9 -f iClawCLI 2>/dev/null || true
      kill -TERM -"$SESSION_PGID" 2>/dev/null || true
      sleep 5
      kill -KILL -"$SESSION_PGID" 2>/dev/null || true
      exit 1
    fi
    sleep 30
  done
) &
SENTINEL_PID=$!

# ---------- resource caps ----------
# 32GB virtual memory per process is a backstop — our daemons normally sit at
# ~2-4GB; anything over 32GB is runaway.
ulimit -v 33554432 2>/dev/null || true

cleanup() {
  kill "$SENTINEL_PID" 2>/dev/null || true
  pkill -9 -f "$REPO_ROOT/.build/debug/iClawCLI" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

CORPUS_ARGS=()
for f in MLTraining/autonomous-baseline.json MLTraining/cycle-probes/*.json; do
  CORPUS_ARGS+=(--corpus "$f")
done

python3 scripts/meta_harness/propose.py \
    --iterations "$ITERS" \
    --claude-timeout 900 \
    "${CORPUS_ARGS[@]}"
