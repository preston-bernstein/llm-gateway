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
log()  { printf '{"schema_version":1,"ts":"%s","level":"%s","service":"llm-gateway-update","event":"%s","msg":"%s"}\n' \
             "$(date -u +%FT%TZ)" "$1" "$2" "${3//\"/\\\"}"; }
info() { log info "$1" "$2"; }
die()  { log critical "$1" "$2" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die preflight.failed "must run as root"

info litellm.upgrade.started "upgrading litellm..."
# prometheus_client backs litellm_settings.callbacks: [prometheus] — keep it
# installed on every update, not just a fresh install.
sudo -u litellm "$VENV/bin/pip" install --quiet --upgrade 'litellm[proxy]' prometheus_client

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
# it never comes up within the RunPod-safe window.
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
systemctl status litellm.service --no-pager | head -10
