#!/usr/bin/env bash
# smoke-model.sh — one timed chat completion through the gateway (:4000).
#
# Sends a single /v1/chat/completions request for the named model and prints:
#   HTTP code, latency in seconds (curl %{time_total}), and the first 120
#   chars of the returned content.
#
# ── COST / LATENCY WARNING ───────────────────────────────────────────────────
# claude-* models route (live overlay, 2026-07-02) to claude-cli-server :4002,
# which wraps Preston's SHARED Claude subscription. Even trivial claude-*
# prompts legitimately take 60–120 s, and every call consumes subscription
# quota that his live Claude Code sessions also depend on. Smoke-test claude-*
# models SPARINGLY — one call to answer a question, never a loop. For cheap
# repeated smoke tests use the local model ollama/batch/qwen3-vl:30b — the
# ONLY serveable ollama/* entry. KNOWN DEFECT (2026-07-02): the qwen2.5*
# entries (ollama/interactive/qwen2.5, ollama/batch/qwen2.5:3b,
# ollama/batch/qwen2.5:7b) are cataloged but their models are not pulled —
# they return HTTP 500 "model not found" even on a healthy gateway.
# gemini-* smoke tests burn free-tier quota (billing is off) — also be gentle.
#
# SECURITY: the LiteLLM master key is read on the REMOTE side only
# (sudo grep on /etc/litellm/litellm.env) and used only inside the remote curl
# header. It is never printed and never leaves the desktop.
#
# READ-ONLY as infrastructure goes: it performs one inference call but never
# restarts, writes, or modifies anything.
#
# Usage: ./smoke-model.sh <model_name> [prompt]
#   model_name = a name from /v1/models, e.g. ollama/batch/qwen3-vl:30b,
#                gemini-2.5-flash, claude-haiku-4-5
#   prompt     = optional; default: 'Reply with exactly: OK'

set -euo pipefail

SSH_TARGET="${GATEWAY_SSH_TARGET:-desktop-agent}"

[ $# -ge 1 ] || { echo "usage: $0 <model_name> [prompt]" >&2; exit 2; }
MODEL="$1"
PROMPT="${2:-Reply with exactly: OK}"

# Build the JSON payload locally with proper escaping.
PAYLOAD=$(python3 - "$MODEL" "$PROMPT" <<'PY'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 100,
}))
PY
)

echo "smoke-test model=$MODEL via http://127.0.0.1:4000 (remote) ..."
case "$MODEL" in
    claude-*) echo "note: claude-* goes through claude-cli-server — expect 60-120 s, uses shared subscription" ;;
esac

# Payload goes over ssh stdin; curl reads it with --data-binary @-.
# -m 330 sits just above LiteLLM's live request_timeout of 300 s (2026-07-02).
raw=$(printf '%s' "$PAYLOAD" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" '
    set -u
    KEY=$(sudo grep "^LITELLM_MASTER_KEY=" /etc/litellm/litellm.env | cut -d= -f2)
    curl -s -m 330 \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        -w "\n__METRICS__ %{http_code} %{time_total}\n" \
        http://127.0.0.1:4000/v1/chat/completions
') || { echo "ERROR: ssh/curl transport failed" >&2; exit 2; }

metrics=$(printf '%s\n' "$raw" | grep '^__METRICS__' | tail -n1)
body=$(printf '%s\n' "$raw" | grep -v '^__METRICS__')
http_code=$(printf '%s' "$metrics" | awk '{print $2}')
latency=$(printf '%s' "$metrics" | awk '{print $3}')

snippet=$(printf '%s' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    content = json.loads(raw)["choices"][0]["message"]["content"]
    print(content[:120].replace("\n", " "))
except Exception:
    print("(no parsable content) " + raw[:120].replace("\n", " "))
')

echo "HTTP code : $http_code"
echo "latency   : ${latency}s"
echo "content   : $snippet"

[ "$http_code" = "200" ] || exit 1
