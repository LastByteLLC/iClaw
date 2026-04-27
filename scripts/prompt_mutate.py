#!/usr/bin/env python3
"""prompt_mutate.py — generate candidate variants of a markdown prompt.

Three mutation operators:

  delete      remove ONE bullet line at a time → N variants
              (N = number of bullets in the file)

  reorder     swap a consecutive pair of sections → N variants
              (N = sections - 1)

  paraphrase  ask the LLM to rewrite ONE bullet, preserving meaning but
              tightening wording → N variants. Uses the iClawCLI daemon's
              `prompt` endpoint.

Output: one `{base}.mut-{id}.md` file per variant under --out, plus a
sidecar `{base}.mut-{id}.json` describing the mutation (op, locus, diff).

Pair with prompt_eval.py to score each variant against the regression
suite.
"""
from __future__ import annotations
import argparse
import json
import os
import subprocess
import sys
from typing import Any

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, ".build", "debug", "iClawCLI")


def parse_sections(text: str) -> list[tuple[str, list[str]]]:
    """Split markdown into (header, [lines]) sections by `##` headings.
    Returns a list preserving order. The preamble (before the first `##`)
    goes under key "__preamble__"."""
    sections: list[tuple[str, list[str]]] = []
    current_key = "__preamble__"
    current: list[str] = []
    for line in text.splitlines():
        if line.startswith("## "):
            sections.append((current_key, current))
            current_key = line
            current = []
        else:
            current.append(line)
    sections.append((current_key, current))
    return sections


def sections_to_text(sections: list[tuple[str, list[str]]]) -> str:
    parts: list[str] = []
    for header, lines in sections:
        if header == "__preamble__":
            parts.append("\n".join(lines))
        else:
            parts.append(header)
            parts.append("\n".join(lines))
    return "\n".join(parts).rstrip() + "\n"


def op_delete(text: str) -> list[tuple[str, dict]]:
    """Return one variant per bullet line deleted."""
    lines = text.splitlines(keepends=False)
    variants: list[tuple[str, dict]] = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("-") or line.lstrip().startswith("*"):
            mutated = lines[:i] + lines[i + 1:]
            variants.append((
                "\n".join(mutated) + "\n",
                {"op": "delete", "line": i, "content": line.strip()},
            ))
    return variants


def op_reorder(text: str) -> list[tuple[str, dict]]:
    """Swap adjacent `## ` sections. One variant per pair."""
    sections = parse_sections(text)
    variants: list[tuple[str, dict]] = []
    for i in range(1, len(sections) - 1):
        if sections[i][0].startswith("## ") and sections[i + 1][0].startswith("## "):
            swapped = sections[:i] + [sections[i + 1], sections[i]] + sections[i + 2:]
            variants.append((
                sections_to_text(swapped),
                {"op": "reorder", "swap": [sections[i][0].strip(), sections[i + 1][0].strip()]},
            ))
    return variants


def op_paraphrase(text: str, count: int) -> list[tuple[str, dict]]:
    """Ask the CLI (LLM) to rewrite one bullet per variant, preserving
    meaning. Caller provides `count` — we pick the first N bullets that
    look substantive (≥6 words)."""
    lines = text.splitlines()
    targets: list[int] = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("-", "*")) and len(line.split()) >= 6:
            targets.append(i)
            if len(targets) >= count: break

    if not targets: return []

    # Spawn a CLI, send paraphrase requests, collect results.
    proc = subprocess.Popen(
        [CLI], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, bufsize=1,
    )

    def recv() -> dict:
        line = proc.stdout.readline()
        return json.loads(line.strip()) if line else {}

    def send(obj: dict) -> None:
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    ready = recv()
    if ready.get("type") != "ready":
        proc.kill()
        return []

    variants: list[tuple[str, dict]] = []
    for idx in targets:
        original = lines[idx].strip().lstrip("-*").strip()
        prompt = (
            "Rewrite this rule as a concise single sentence. "
            "Preserve meaning and intent. No commentary, just the rule.\n\n"
            f"Original: {original}\nRewritten:"
        )
        send({"type": "prompt", "text": prompt})
        r = recv()
        rewritten = (r.get("text") or "").strip().split("\n", 1)[0].strip()
        if not rewritten or rewritten == original: continue
        new_lines = lines[:]
        # Preserve the leading bullet character + indentation.
        prefix = lines[idx][: len(lines[idx]) - len(lines[idx].lstrip())] + "- "
        new_lines[idx] = prefix + rewritten
        variants.append((
            "\n".join(new_lines) + "\n",
            {"op": "paraphrase", "line": idx, "original": original, "rewritten": rewritten},
        ))

    send({"type": "quit"})
    proc.wait(timeout=5)
    return variants


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True, help="Path to source markdown prompt")
    p.add_argument("--out", required=True, help="Output directory for variants")
    p.add_argument("--ops", default="delete,reorder",
                   help="Comma-separated ops: delete, reorder, paraphrase")
    p.add_argument("--count", type=int, default=5,
                   help="Max variants per op (applies to paraphrase; delete/reorder are exhaustive).")
    p.add_argument("--prefix", default=None,
                   help="Variant file prefix (defaults to the base file stem).")
    args = p.parse_args()

    if not os.path.exists(args.base):
        print(f"error: base not found: {args.base}", file=sys.stderr)
        return 2
    with open(args.base) as f:
        text = f.read()

    os.makedirs(args.out, exist_ok=True)
    prefix = args.prefix or os.path.splitext(os.path.basename(args.base))[0]

    ops_list = [o.strip() for o in args.ops.split(",") if o.strip()]
    all_variants: list[tuple[str, dict]] = []
    for op in ops_list:
        if op == "delete":
            all_variants += op_delete(text)
        elif op == "reorder":
            all_variants += op_reorder(text)
        elif op == "paraphrase":
            all_variants += op_paraphrase(text, args.count)
        else:
            print(f"warning: unknown op {op!r}", file=sys.stderr)

    # Cap per-op count (delete/reorder can explode on large prompts)
    if len(all_variants) > args.count * len(ops_list):
        all_variants = all_variants[: args.count * len(ops_list)]

    written = []
    for i, (content, meta) in enumerate(all_variants):
        tag = f"mut-{i:03d}"
        md_path = os.path.join(args.out, f"{prefix}.{tag}.md")
        json_path = os.path.join(args.out, f"{prefix}.{tag}.json")
        with open(md_path, "w") as f:
            f.write(content)
        with open(json_path, "w") as f:
            json.dump({"base": args.base, "tag": tag, "mutation": meta}, f, indent=2)
        written.append(tag)

    print(f"Wrote {len(written)} variants to {args.out}")
    for t in written: print(f"  {t}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
