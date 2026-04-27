#!/bin/bash
# afm-query.sh — Query Apple Foundation Models via the local maclocal-api server.
# Usage:
#   ./Scripts/afm-query.sh "Your prompt here"
#   ./Scripts/afm-query.sh -s "system prompt" "user prompt"
#   ./Scripts/afm-query.sh -t 0.0 "deterministic prompt"
#   ./Scripts/afm-query.sh -j "prompt"  # raw JSON output

set -euo pipefail

AFM_URL="${AFM_URL:-http://127.0.0.1:9999}"
MODEL="${AFM_MODEL:-foundation}"
TEMPERATURE="0.7"
MAX_TOKENS="1024"
SYSTEM_PROMPT=""
RAW_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--system) SYSTEM_PROMPT="$2"; shift 2 ;;
        -t|--temperature) TEMPERATURE="$2"; shift 2 ;;
        -m|--max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        -j|--json) RAW_JSON=true; shift ;;
        -h|--help)
            echo "Usage: afm-query.sh [-s system_prompt] [-t temp] [-m max_tokens] [-j] prompt"
            exit 0 ;;
        *) break ;;
    esac
done

PROMPT="${1:?Usage: afm-query.sh [options] \"prompt\"}"

# Build messages array
if [[ -n "$SYSTEM_PROMPT" ]]; then
    MESSAGES=$(python3 -c "
import json
msgs = [
    {'role': 'system', 'content': $(python3 -c "import json; print(json.dumps('$SYSTEM_PROMPT'))")},
    {'role': 'user', 'content': $(python3 -c "import json; print(json.dumps('''$PROMPT'''))")}
]
print(json.dumps(msgs))
")
else
    MESSAGES=$(python3 -c "
import json
msgs = [{'role': 'user', 'content': $(python3 -c "import json; print(json.dumps('''$PROMPT'''))")}]
print(json.dumps(msgs))
")
fi

BODY=$(python3 -c "
import json
print(json.dumps({
    'model': '$MODEL',
    'messages': $MESSAGES,
    'temperature': $TEMPERATURE,
    'max_tokens': int($MAX_TOKENS)
}))
")

RESPONSE=$(curl -s -X POST "$AFM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$BODY")

if $RAW_JSON; then
    echo "$RESPONSE" | python3 -m json.tool
else
    echo "$RESPONSE" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    content = r['choices'][0]['message']['content']
    usage = r.get('usage', {})
    tokens = usage.get('total_tokens', '?')
    print(content)
    print(f'\n--- ({tokens} tokens) ---', file=sys.stderr)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
"
fi
