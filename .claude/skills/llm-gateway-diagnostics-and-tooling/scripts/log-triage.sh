#!/usr/bin/env bash
# log-triage.sh — bucket litellm journal errors by pattern, with counts.
#
# Pulls `journalctl -u litellm` on the desktop for a time window and counts
# error lines per bucket, plus one truncated example line per bucket:
#
#   timeout      APITimeoutError / litellm.exceptions.Timeout
#   auth         authentication errors / invalid or missing key / 401
#   rate-limit   RateLimitError / 429 (Gemini free tier is quota-fragile)
#   conn-refused connection refused / connect errors (backend down)
#   other        any other line containing error/exception/traceback
#
# The journal is HUGE (~2.5M lines/24h measured 2026-07-02), so the entire
# journalctl|awk pipeline runs on the REMOTE side in a single pass — only the
# summary table crosses the wire.
#
# READ-ONLY: this script never restarts, writes, or modifies anything.
#
# REDACTION: example lines are raw journal excerpts. LiteLLM's
# redact_user_api_key_info covers proxy-side key info, but client-supplied
# junk is not guaranteed clean — redact any Bearer/Authorization-shaped
# substrings before pasting output into notes, reports, or skills.
#
# Usage: ./log-triage.sh [WINDOW]
#   WINDOW = anything journalctl --since accepts. Default: "-24 hours".
#   Examples: ./log-triage.sh "-1 hour"
#             ./log-triage.sh "2026-07-02 09:00"

set -euo pipefail

SSH_TARGET="${GATEWAY_SSH_TARGET:-desktop-agent}"
WINDOW="${1:--24 hours}"

echo "litellm journal triage — window: since '$WINDOW' (unit: litellm.service)"
echo

# Quoted heredoc: nothing expands locally. ssh flattens its arguments into ONE
# remote command string, so the window is shell-quoted with printf %q and
# embedded in that string — it arrives intact as $1 even with spaces.
WINDOW_Q=$(printf '%q' "$WINDOW")
ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" "bash -s -- $WINDOW_Q" <<'REMOTE'
set -euo pipefail
WINDOW="$1"
sudo journalctl -u litellm --since "$WINDOW" --no-pager -o cat | awk '
function keep(bucket, line) {
    count[bucket]++
    if (!(bucket in example)) example[bucket] = substr(line, 1, 160)
}
{
    total++
    gsub(/\033\[[0-9;]*m/, "")   # strip ANSI color codes from example lines
    low = tolower($0)
    if (low ~ /apitimeouterror|litellm\.exceptions\.timeout/)        { keep("timeout", $0);      next }
    if (low ~ /authenticationerror|authentication error|invalid.*(api key|master key)|no api key|401 unauthorized/) { keep("auth", $0); next }
    if (low ~ /ratelimiterror|429|rate limit/)                       { keep("rate-limit", $0);   next }
    if (low ~ /connection refused|connecterror|connectionerror|cannot connect to host/) { keep("conn-refused", $0); next }
    if (low ~ /error|exception|traceback/)                           { keep("other", $0);        next }
}
END {
    n = split("timeout auth rate-limit conn-refused other", order, " ")
    printf "%-14s %8s   %s\n", "BUCKET", "COUNT", "FIRST EXAMPLE (truncated)"
    errors = 0
    for (i = 1; i <= n; i++) {
        b = order[i]
        c = (b in count) ? count[b] : 0
        errors += c
        printf "%-14s %8d   %s\n", b, c, (b in example) ? example[b] : "-"
    }
    printf "\n%d error-ish lines out of %d journal lines scanned.\n", errors, total
}'
REMOTE
