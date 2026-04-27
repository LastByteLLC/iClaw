#!/usr/bin/env python3
"""
iclaw-daemon.py — Wrapper for driving iClawCLI as a persistent subprocess.

Starts iClawCLI, sends commands, and receives responses. Designed for use
by Claude Code or any external tool that wants to interact with the full
iClaw execution pipeline (routing, tools, finalization, widgets).

Usage:
    # Interactive mode (human-friendly)
    python3 Scripts/iclaw-daemon.py

    # Single prompt (pipe-friendly)
    python3 Scripts/iclaw-daemon.py --prompt "What's the weather?"

    # Batch mode (reads prompts from file, one per line)
    python3 Scripts/iclaw-daemon.py --batch prompts.txt

    # Settings
    python3 Scripts/iclaw-daemon.py --set personalityLevel=neutral --prompt "Hello"
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time

CLI_BINARY = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ".build", "debug", "iClawCLI"
)


class iClawDaemon:
    """Manages iClawCLI as a long-lived subprocess."""

    def __init__(self, binary_path: str = CLI_BINARY):
        self.binary_path = binary_path
        self.process = None

    def start(self) -> str:
        """Start the daemon. Returns the ready message."""
        if not os.path.exists(self.binary_path):
            raise FileNotFoundError(
                f"iClawCLI not found at {self.binary_path}\n"
                f"Build it first: make cli"
            )

        self.process = subprocess.Popen(
            [self.binary_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # Line buffered
        )

        # Wait for ready signal
        ready = self._read_response()
        if ready.get("type") != "ready":
            raise RuntimeError(f"Unexpected startup response: {ready}")
        return ready.get("message", "ready")

    def stop(self):
        """Stop the daemon gracefully."""
        if self.process and self.process.poll() is None:
            try:
                self._send({"type": "quit"})
                self.process.wait(timeout=5)
            except Exception:
                self.process.kill()
        self.process = None

    def prompt(self, text: str) -> dict:
        """Send a prompt and return the response."""
        self._send({"type": "prompt", "text": text})
        return self._read_response()

    def set_setting(self, key: str, value: str) -> dict:
        """Set a UserDefaults setting."""
        self._send({"type": "setting", "key": key, "value": value})
        return self._read_response()

    def get_setting(self, key: str) -> dict:
        """Get a UserDefaults setting."""
        self._send({"type": "setting_get", "key": key})
        return self._read_response()

    def status(self) -> dict:
        """Get current daemon status."""
        self._send({"type": "status"})
        return self._read_response()

    def reset(self) -> dict:
        """Reset conversation state."""
        self._send({"type": "reset"})
        return self._read_response()

    def _send(self, command: dict):
        if not self.process or self.process.poll() is not None:
            raise RuntimeError("Daemon not running")
        line = json.dumps(command) + "\n"
        self.process.stdin.write(line)
        self.process.stdin.flush()

    def _read_response(self, timeout: float = 60.0) -> dict:
        if not self.process:
            raise RuntimeError("Daemon not running")

        # Simple blocking read — iClawCLI writes one JSON line per response
        line = self.process.stdout.readline()
        if not line:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise RuntimeError(f"Daemon closed unexpectedly. stderr: {stderr[:500]}")

        return json.loads(line.strip())

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *args):
        self.stop()


def interactive(daemon: iClawDaemon):
    """Interactive REPL."""
    print("iClaw CLI Daemon (type /help for commands, /quit to exit)")
    print()

    while True:
        try:
            user_input = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not user_input:
            continue

        if user_input in ("/quit", "/exit", "/q"):
            break

        if user_input == "/help":
            print("  /set KEY VALUE  — Change a setting")
            print("  /get KEY        — Read a setting")
            print("  /status         — Show daemon status")
            print("  /reset          — Reset conversation")
            print("  /quit           — Exit")
            print("  (anything else) — Send as prompt")
            print()
            continue

        if user_input.startswith("/set "):
            parts = user_input[5:].split(maxsplit=1)
            if len(parts) == 2:
                r = daemon.set_setting(parts[0], parts[1])
                print(f"  {r.get('key')} = {r.get('value')}")
            else:
                print("  Usage: /set KEY VALUE")
            print()
            continue

        if user_input.startswith("/get "):
            key = user_input[5:].strip()
            r = daemon.get_setting(key)
            print(f"  {r.get('key')} = {r.get('value')}")
            print()
            continue

        if user_input == "/status":
            r = daemon.status()
            print(f"  Turns: {r.get('turnCount', 0)}")
            facts = r.get('facts', [])
            if facts:
                print(f"  Facts:")
                for f in facts:
                    print(f"    [{f['tool']}] {f['key']}: {f['value']}")
            settings = r.get('settings', {})
            if settings:
                print(f"  Settings: {settings}")
            print()
            continue

        if user_input == "/reset":
            r = daemon.reset()
            print(f"  {r.get('message', 'Reset')}")
            print()
            continue

        # Send as prompt
        r = daemon.prompt(user_input)
        if r.get("type") == "error":
            print(f"  Error: {r.get('message')}")
        else:
            routed = r.get("key", "?")
            ms = r.get("durationMs", 0)
            widget = r.get("widgetType")
            err = r.get("isError", False)
            prefix = "ERROR" if err else "iClaw"
            print(f"{prefix}> {r.get('text', '')}")
            meta_parts = [f"{ms}ms", f"tool={routed}"]
            if widget:
                meta_parts.append(f"widget={widget}")
            print(f"  [{', '.join(meta_parts)}]")
        print()


def main():
    parser = argparse.ArgumentParser(description="iClaw CLI Daemon wrapper")
    parser.add_argument("--prompt", "-p", type=str, help="Single prompt (exit after response)")
    parser.add_argument("--batch", "-b", type=str, help="File with prompts, one per line")
    parser.add_argument("--set", action="append", help="Set KEY=VALUE before running")
    parser.add_argument("--json", "-j", action="store_true", help="Output raw JSON")
    parser.add_argument("--binary", type=str, default=CLI_BINARY, help="Path to iClawCLI binary")

    args = parser.parse_args()

    with iClawDaemon(binary_path=args.binary) as daemon:
        # Apply settings
        if args.set:
            for s in args.set:
                k, v = s.split("=", 1)
                daemon.set_setting(k, v)

        if args.prompt:
            r = daemon.prompt(args.prompt)
            if args.json:
                print(json.dumps(r, indent=2))
            else:
                print(r.get("text", ""))
        elif args.batch:
            with open(args.batch) as f:
                prompts = [l.strip() for l in f if l.strip() and not l.startswith("#")]
            for prompt in prompts:
                r = daemon.prompt(prompt)
                if args.json:
                    print(json.dumps(r))
                else:
                    routed = r.get("key", "?")
                    ms = r.get("durationMs", 0)
                    err = "ERR " if r.get("isError") else ""
                    print(f"[{routed}] {err}({ms}ms) {prompt[:50]}")
                    print(f"  → {r.get('text', '')[:200]}")
                    print()
        else:
            interactive(daemon)


if __name__ == "__main__":
    main()
