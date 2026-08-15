#!/usr/bin/env bash
# Pull latest config and restart the service.
# Run as root on the target machine.
set -euo pipefail

VENV=/opt/litellm/venv
CONFIG_DIR=/etc/litellm
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEALTH_URL="http://127.0.0.1:4000/health/liveliness"
HEALTH_TIMEOUT_S=30

# Structured logging (home-infra CONVENTIONS.md §18 Shell house style).
SERVICE_NAME=llm-gateway-update
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $EUID -eq 0 ]] || die preflight.failed "must run as root"

info litellm.upgrade.started "upgrading litellm..."
# prometheus_client backs litellm_settings.callbacks: [prometheus] — keep it
# installed on every update, not just a fresh install.
sudo -u litellm "$VENV/bin/pip" install --quiet --upgrade 'litellm[proxy]' prometheus_client
if LITELLM_VERSION=$("$VENV/bin/litellm" --version 2>&1); then
    info litellm.upgrade.completed "upgraded to litellm $LITELLM_VERSION"
else
    log critical litellm.version_check_failed "litellm --version failed after upgrade: ${LITELLM_VERSION//\"/\\\"}"
    LITELLM_VERSION=unknown
fi

info config.sync.started "syncing config..."
cp "$REPO_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"
chown root:litellm "$CONFIG_DIR/config.yaml"
chmod 640 "$CONFIG_DIR/config.yaml"
cp "$REPO_DIR/systemd/litellm.service" /etc/systemd/system/litellm.service
systemctl daemon-reload

info service.restart.started "restarting service..."
systemctl restart litellm.service

# A bare `sleep 2` + status print (the old behavior here) cannot tell a
# restart apart from a config-error crash-loop: Restart=always means a broken
# config cycles in `activating (auto-restart)` forever and never reaches
# systemd's `failed` state (2026-08-01 fleet audit gap — this is Incident 1's
# failure shape exactly). Poll the health endpoint instead and fail loudly if
# it never comes up within a generous window for litellm's own startup time
# (venv activation + provider client init), not related to RunPod at all —
# this polls the local proxy's own liveliness endpoint.
elapsed=0
until curl -fsS -m 2 "$HEALTH_URL" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$HEALTH_TIMEOUT_S" ]]; then
        log critical service.restart.failed "litellm did not report healthy within ${HEALTH_TIMEOUT_S}s of restart — check: systemctl status litellm --no-pager; journalctl -u litellm -n 50" >&2
        systemctl status litellm.service --no-pager | head -10 >&2
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
info service.restart.completed "litellm healthy after restart (${elapsed}s)"

# litellm/vLLM version is unpinned above, but the whole Observability section
# (README.md) depends on the Prometheus integration staying wired up the way
# it was doc-verified. Liveliness alone can't catch that breaking. This is
# deliberately a *shallow* check, not a check for README's specific series
# names: litellm_proxy_total_requests_metric, litellm_deployment_*_fallbacks,
# litellm_deployment_cooled_down, and litellm_spend_metric are all
# event-labeled Prometheus counters that don't exist in the exposition output
# until a matching request/fallback/cooldown actually happens — checking for
# their unconditional presence right after a fresh restart with zero traffic
# false-positives every single time (found live, 2026-08-11: this exact
# check fired "missing" on all four on first deploy with none of them
# actually broken). Instead just confirm the endpoint is reachable and still
# exporting *some* litellm_ series — enough to catch the callback breaking
# entirely (auth change, dependency removed, exposition format changed)
# without asserting on data that legitimately doesn't exist yet.
# Never echo the master key itself — read it straight into the curl header.
MASTER_KEY="$(grep -m1 '^LITELLM_MASTER_KEY=' "$CONFIG_DIR/litellm.env" | cut -d= -f2-)"
METRICS_BODY="$(curl -fsSL -m 5 -H "Authorization: Bearer $MASTER_KEY" http://127.0.0.1:4000/metrics 2>/dev/null || true)"
if [[ -z "$METRICS_BODY" ]]; then
    log critical metrics.check_failed "could not fetch /metrics after restart — cannot confirm the Prometheus integration is still working"
elif ! grep -q '^litellm_' <<< "$METRICS_BODY"; then
    log critical metrics.wiring_broken "litellm upgrade to $LITELLM_VERSION may have broken the prometheus callback — /metrics responded but exported no litellm_ series"
else
    info metrics.check_passed "/metrics reachable and exporting litellm_ series after upgrade"
fi

systemctl status litellm.service --no-pager | head -10
