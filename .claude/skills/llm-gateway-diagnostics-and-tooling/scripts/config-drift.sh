#!/usr/bin/env bash
# config-drift.sh — diff the LIVE gateway config against the REPO config.
#
# Live:  /etc/litellm/config.yaml on the desktop (fetched via ssh + sudo cat)
# Repo:  config/config.yaml in this repo (canonical-in-git)
#
# Exit 0 + "NO DRIFT"  -> files are byte-identical.
# Exit 1 + unified diff -> drift exists (lines prefixed `-` are LIVE-only,
#                          lines prefixed `+` are REPO-only).
#
# ── DRIFT IS EXPECTED as of 2026-07-02 ───────────────────────────────────────
# The live config is deliberately AHEAD of the repo (a local overlay):
#   1. all four claude-* models route to openai/<model> at
#      api_base http://localhost:4002/v1 (claude-cli-server, subscription
#      billing) instead of the repo's anthropic/ + ANTHROPIC_API_KEY
#      (API billing — that account is out of credits, so the repo routing
#      would make every claude-* call FAIL);
#   2. live adds claude-fable-5 (absent from the repo config);
#   3. live request_timeout: 300 vs repo 120.
# So a non-empty diff showing exactly those three things is the KNOWN state,
# not an emergency. A diff showing anything ELSE is real, uninvestigated drift.
#
# WHAT TO DO ABOUT IT: do NOT "fix" the drift by running scripts/update.sh —
# update.sh copies the repo config over the live one UNCONDITIONALLY and
# restarts, which would break all claude-* traffic and drop claude-fable-5.
# Reconciliation is an open decision with a decision menu in the
# llm-gateway-timeout-and-drift-campaign skill. Route any change through
# llm-gateway-change-control.
#
# SECURITY: config.yaml contains no secrets (os.environ/ references only),
# so displaying the diff is safe. /etc/litellm/litellm.env is never touched.
#
# READ-ONLY: this script never restarts, writes, or modifies anything.
#
# Usage: ./config-drift.sh

set -euo pipefail

SSH_TARGET="${GATEWAY_SSH_TARGET:-desktop-agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REPO_CONFIG="$REPO_DIR/config/config.yaml"

[ -f "$REPO_CONFIG" ] || { echo "ERROR: repo config not found at $REPO_CONFIG" >&2; exit 2; }

live_config=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
    'sudo cat /etc/litellm/config.yaml') \
    || { echo "ERROR: could not fetch live config via ssh $SSH_TARGET" >&2; exit 2; }

diff_rc=0
diff_out=$(printf '%s\n' "$live_config" | diff -u \
    --label 'live:/etc/litellm/config.yaml' \
    --label "repo:config/config.yaml" \
    - "$REPO_CONFIG") || diff_rc=$?

if [ "$diff_rc" -eq 0 ]; then
    echo "NO DRIFT"
    exit 0
elif [ "$diff_rc" -eq 1 ]; then
    echo "DRIFT DETECTED (live vs repo). '-' lines = live-only, '+' lines = repo-only."
    echo "Expected as of 2026-07-02: claude-* -> :4002, claude-fable-5, request_timeout 300."
    echo "Anything beyond that is NEW drift. Do NOT run scripts/update.sh to reconcile."
    echo
    printf '%s\n' "$diff_out"
    exit 1
else
    echo "ERROR: diff failed (rc=$diff_rc)" >&2
    exit 2
fi
