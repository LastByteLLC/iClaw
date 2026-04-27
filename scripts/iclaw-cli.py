#!/usr/bin/env python3
"""
iclaw-cli.py — CLI interface to iClaw's agent pipeline via maclocal-api.

Exercises the same logic as iClaw's ExecutionEngine but through the local
AFM API server (http://127.0.0.1:9999), allowing Claude Code and other
tools to submit prompts, test routing, and validate the agent pipeline
without the GUI.

Usage:
    python3 Scripts/iclaw-cli.py "What's the weather in Tokyo?"
    python3 Scripts/iclaw-cli.py --plan "Book a walking lunch with Sarah the next sunny day"
    python3 Scripts/iclaw-cli.py --classify "flip a coin and check the weather"
    python3 Scripts/iclaw-cli.py --route "What is AAPL trading at?"
    python3 Scripts/iclaw-cli.py --domains
    python3 Scripts/iclaw-cli.py --interactive
"""

import argparse
import json
import sys
import urllib.request

AFM_URL = "http://127.0.0.1:9999/v1/chat/completions"
MODEL = "foundation"

# Tool domains matching Agent/ToolDomain.swift
TOOL_DOMAINS = {
    "weather": ["Weather", "Clock", "Today"],
    "productivity": ["Calendar", "Timer", "Reminders", "Notes", "Shortcuts"],
    "finance": ["Stocks", "Convert", "Calculator", "Compute"],
    "media": ["Podcast", "Transcribe", "Spotlight", "Music"],
    "communication": ["Email", "Messages", "Contacts", "ReadEmail"],
    "research": ["WebFetch", "WebSearch", "News", "WikipediaSearch", "Wikipedia", "Research"],
    "system": ["SystemInfo", "SystemControl", "Screenshot", "TechSupport", "Automate",
                "Clipboard", "ReadFile"],
    "utility": ["Random", "Dictionary", "Translate", "Maps", "Help", "Feedback", "Import"],
}

ALL_TOOLS = sorted(set(t for tools in TOOL_DOMAINS.values() for t in tools))


def afm_call(system: str, user: str, temperature: float = 0, max_tokens: int = 500) -> str:
    """Send a chat completion request to the local AFM server."""
    body = json.dumps({
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }).encode()

    req = urllib.request.Request(
        AFM_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            return data["choices"][0]["message"]["content"]
    except Exception as e:
        return f"[AFM Error: {e}]"


def classify_complexity(prompt: str) -> dict:
    """Classify query complexity using the same logic as ComplexityGate."""
    system = (
        "Analyze this request and output JSON with these fields:\n"
        "- isSingleStep (bool): true if only one tool/action is needed\n"
        "- hasDependentSteps (bool): true if one tool's output feeds another\n"
        "- hasParallelIntents (bool): true if multiple independent actions requested\n"
        "- estimatedSteps (int): number of tool calls needed (1-4)\n"
        "Output only valid JSON."
    )
    result = afm_call(system, prompt)
    # Strip markdown code fences if present
    result = result.strip()
    if result.startswith("```"):
        result = "\n".join(result.split("\n")[1:])
    if result.endswith("```"):
        result = result.rsplit("```", 1)[0]
    try:
        return json.loads(result.strip())
    except json.JSONDecodeError:
        return {"raw": result, "error": "Could not parse JSON"}


def route_tool(prompt: str, domain: str = None) -> str:
    """Route a query to a tool, optionally within a specific domain."""
    if domain and domain in TOOL_DOMAINS:
        tools = TOOL_DOMAINS[domain]
    else:
        tools = ALL_TOOLS

    system = (
        f"Pick the single best tool for this request. "
        f"Available tools: {', '.join(tools)}. "
        f"Output only the tool name, nothing else."
    )
    return afm_call(system, prompt).strip()


def generate_plan(prompt: str) -> dict:
    """Generate an execution plan using the same logic as AgentPlanner."""
    system = (
        "You are a task planner. Decompose the user's request into 1-3 tool steps.\n"
        f"Available tools: {', '.join(ALL_TOOLS)}.\n"
        "Rules:\n"
        "- Most requests need only 1 step\n"
        "- Use multiple steps only when one tool's output is needed by another\n"
        "- For parallel requests, create separate independent steps\n"
        "Output JSON: {steps: [{toolName, input, dependsOnPrevious}]}"
    )
    result = afm_call(system, prompt, max_tokens=400)
    result = result.strip()
    if result.startswith("```"):
        result = "\n".join(result.split("\n")[1:])
    if result.endswith("```"):
        result = result.rsplit("```", 1)[0]
    try:
        return json.loads(result.strip())
    except json.JSONDecodeError:
        return {"raw": result, "error": "Could not parse JSON"}


def chat(prompt: str, system_override: str = None) -> str:
    """Send a general chat prompt to AFM."""
    system = system_override or (
        "You are iClaw, a helpful AI assistant running on macOS. "
        "Be concise and direct. If the user asks about capabilities, "
        "mention you can check weather, stocks, calendar, set timers, "
        "do math, search the web, translate, and more."
    )
    return afm_call(system, prompt, temperature=0.7, max_tokens=1024)


def interactive():
    """Interactive REPL mode."""
    print("iClaw CLI (via AFM @ 127.0.0.1:9999)")
    print("Commands: /plan, /route, /classify, /domain <name>, /quit")
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

        if user_input.startswith("/plan "):
            query = user_input[6:]
            plan = generate_plan(query)
            print(json.dumps(plan, indent=2))

        elif user_input.startswith("/route "):
            query = user_input[7:]
            tool = route_tool(query)
            print(f"→ {tool}")

        elif user_input.startswith("/classify "):
            query = user_input[10:]
            result = classify_complexity(query)
            print(json.dumps(result, indent=2))

        elif user_input.startswith("/domain"):
            parts = user_input.split(maxsplit=1)
            if len(parts) < 2:
                for name, tools in sorted(TOOL_DOMAINS.items()):
                    print(f"  {name}: {', '.join(tools)}")
            else:
                name = parts[1]
                if name in TOOL_DOMAINS:
                    print(f"  {name}: {', '.join(TOOL_DOMAINS[name])}")
                else:
                    print(f"  Unknown domain: {name}")

        else:
            response = chat(user_input)
            print(f"iClaw> {response}")

        print()


def main():
    parser = argparse.ArgumentParser(description="iClaw CLI via maclocal-api")
    parser.add_argument("prompt", nargs="?", help="Prompt to send")
    parser.add_argument("--plan", action="store_true", help="Generate execution plan")
    parser.add_argument("--classify", action="store_true", help="Classify query complexity")
    parser.add_argument("--route", action="store_true", help="Route to best tool")
    parser.add_argument("--domain", type=str, help="Restrict routing to a domain")
    parser.add_argument("--domains", action="store_true", help="List tool domains")
    parser.add_argument("--interactive", "-i", action="store_true", help="Interactive mode")
    parser.add_argument("--json", "-j", action="store_true", help="Output raw JSON")

    args = parser.parse_args()

    if args.interactive:
        interactive()
        return

    if args.domains:
        for name, tools in sorted(TOOL_DOMAINS.items()):
            print(f"{name}: {', '.join(tools)}")
        return

    if not args.prompt:
        parser.print_help()
        sys.exit(1)

    if args.classify:
        result = classify_complexity(args.prompt)
        print(json.dumps(result, indent=2))
    elif args.plan:
        result = generate_plan(args.prompt)
        print(json.dumps(result, indent=2))
    elif args.route:
        tool = route_tool(args.prompt, domain=args.domain)
        print(tool)
    else:
        response = chat(args.prompt)
        print(response)


if __name__ == "__main__":
    main()
