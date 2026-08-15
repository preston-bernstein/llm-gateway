#!/usr/bin/env bash
# gateway-health.sh — one-shot read-only health sweep of the llm-gateway stack.
#
# Run FROM THE MAC. Uses `ssh desktop-agent` (agent user, NOPASSWD sudo) to run
# every probe on the desktop itself (all services bind localhost there).
#
# Checks (one PASS/FAIL line each):
#   1. litellm.service active
#   2. gateway /health/liveliness returns 200 (no auth required)
#   3. gateway /v1/models returns 200 with auth + model count
#   4. claude-cli-server.service active
#   5. claude-cli-server :4002 /v1/models returns 200
#   6. broker interactive lane :11435 /api/tags returns 200
#   7. broker batch lane :11436 /api/tags returns 200
#
# SECURITY: the LiteLLM master key is read on the REMOTE side only
# (sudo grep on /etc/litellm/litellm.env) and used only inside the remote curl
# header. It is never printed, never leaves the desktop, never touches this
# Mac's shell history or stdout.
#
# READ-ONLY: this script never restarts, writes, or modifies anything.
#
# Usage: ./gateway-health.sh
# Exit:  0 = all checks PASS; N>0 = N checks FAILed; 99 = SSH unreachable.

set -euo pipefail

SSH_TARGET="${GATEWAY_SSH_TARGET:-desktop-agent}"

# Everything below runs on the desktop. Quoted heredoc: nothing expands locally.
rc=0
ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" 'bash -s' <<'REMOTE' || rc=$?
set -u
fails=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# 1. litellm.service
if [ "$(systemctl is-active litellm.service 2>/dev/null || true)" = "active" ]; then
    pass "litellm.service active"
else
    fail "litellm.service NOT active ($(systemctl is-active litellm.service 2>/dev/null || echo unknown))"
fi

# 2. /health/liveliness (unauthenticated by design)
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:4000/health/liveliness || true)
code="${code:-000}"; code="${code: -3}"
if [ "$code" = "200" ]; then
    pass "gateway :4000 /health/liveliness -> 200"
else
    fail "gateway :4000 /health/liveliness -> $code (expected 200; 000 = no HTTP response)"
fi

# 3. /v1/models with master key (key stays in this remote shell only)
KEY=$(sudo grep '^LITELLM_MASTER_KEY=' /etc/litellm/litellm.env | cut -d= -f2)
resp=$(curl -s -m 15 -w '\n%{http_code}' -H "Authorization: Bearer $KEY" \
    http://127.0.0.1:4000/v1/models || echo '
000')
unset KEY
code=$(printf '%s' "$resp" | tail -n1)
if [ "$code" = "200" ]; then
    nmodels=$(printf '%s' "$resp" | sed '$d' | grep -o '"id"' | wc -l | tr -d ' ')
    pass "gateway :4000 /v1/models -> 200 ($nmodels models; baseline 2026-07-02: 10)"
else
    fail "gateway :4000 /v1/models -> $code (expected 200; 500 = no auth header sent; 400 'No connected db.' = wrong key)"
fi

# 4. claude-cli-server.service
if [ "$(systemctl is-active claude-cli-server.service 2>/dev/null || true)" = "active" ]; then
    pass "claude-cli-server.service active"
else
    fail "claude-cli-server.service NOT active ($(systemctl is-active claude-cli-server.service 2>/dev/null || echo unknown))"
fi

# 5. claude-cli-server :4002 /v1/models (no auth; binds 127.0.0.1 only)
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:4002/v1/models || true)
code="${code:-000}"; code="${code: -3}"
if [ "$code" = "200" ]; then
    pass "claude-cli-server :4002 /v1/models -> 200"
else
    fail "claude-cli-server :4002 /v1/models -> $code (expected 200; 000 = shim down/refused)"
fi

# 6+7. broker lanes (resource-broker; NEVER raw :11434)
for port in 11435 11436; do
    lane="interactive"; [ "$port" = "11436" ] && lane="batch"
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${port}/api/tags" || true)
    code="${code:-000}"; code="${code: -3}"
    if [ "$code" = "200" ]; then
        pass "broker $lane lane :$port /api/tags -> 200"
    else
        fail "broker $lane lane :$port /api/tags -> $code (000 = broker down or GPU yielded — NOT a gateway bug)"
    fi
done

exit "$fails"
REMOTE

if [ "$rc" -eq 255 ]; then
    echo "FAIL  ssh $SSH_TARGET unreachable — cannot run any checks" >&2
    exit 99
fi
exit "$rc"
