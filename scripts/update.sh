#!/usr/bin/env bash
# Pull latest config and restart the service.
# Run as root on the target machine.
set -euo pipefail

VENV=/opt/litellm/venv
CONFIG_DIR=/etc/litellm
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

echo "[update] upgrading litellm..."
sudo -u litellm "$VENV/bin/pip" install --quiet --upgrade 'litellm[proxy]'

echo "[update] syncing config..."
cp "$REPO_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"
cp "$REPO_DIR/systemd/litellm.service" /etc/systemd/system/litellm.service
systemctl daemon-reload

echo "[update] restarting service..."
systemctl restart litellm.service
sleep 2
systemctl status litellm.service --no-pager | head -10
