#!/usr/bin/env bash
# Install LiteLLM proxy as a systemd service under a dedicated service user.
# Run as root on the target machine.
set -euo pipefail

VENV=/opt/litellm/venv
CONFIG_DIR=/etc/litellm
DATA_DIR=/var/lib/litellm
SERVICE_USER=litellm
PORT=4000

# Structured logging (home-infra CONVENTIONS.md §18 Shell house style).
# Kept to install-time state changes worth having a record of; the final
# "what to do next" banner at the bottom stays plain stdout — that's
# operator UX text for whoever ran this interactively, not a log event.
SERVICE_NAME=llm-gateway-install
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $EUID -eq 0 ]] || die preflight.failed "must run as root"
command -v python3 >/dev/null || die preflight.failed "python3 not found"
command -v openssl >/dev/null || die preflight.failed "openssl not found"

# ── Service user ──────────────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" -m "$SERVICE_USER"
    info service_user.created "created service user $SERVICE_USER"
else
    info service_user.exists "service user $SERVICE_USER already exists"
fi

# ── Directories ───────────────────────────────────────────────────────────────
# $DATA_DIR is created and owned by `useradd -m` above (and later by
# StateDirectory=litellm on every service start) — not re-created here.
mkdir -p /opt/litellm "$CONFIG_DIR"
chown "$SERVICE_USER:$SERVICE_USER" /opt/litellm
chown root:"$SERVICE_USER" "$CONFIG_DIR"
chmod 750 "$CONFIG_DIR"   # litellm group can traverse; root:root locked

# ── Python venv + LiteLLM ─────────────────────────────────────────────────────
info venv.creating "creating venv at $VENV ..."
sudo -u "$SERVICE_USER" python3 -m venv "$VENV"
info litellm.installing "installing litellm[proxy] + prometheus_client ..."
sudo -u "$SERVICE_USER" "$VENV/bin/pip" install --quiet --upgrade pip
# prometheus_client backs litellm_settings.callbacks: [prometheus] in
# config.yaml — the native /metrics endpoint (home-infra CONVENTIONS.md §18).
sudo -u "$SERVICE_USER" "$VENV/bin/pip" install --quiet 'litellm[proxy]' prometheus_client
if LITELLM_VERSION=$("$VENV/bin/litellm" --version 2>&1); then
    info litellm.installed "installed litellm $LITELLM_VERSION"
else
    log critical litellm.version_check_failed "litellm --version failed after install: ${LITELLM_VERSION//\"/\\\"}"
fi

# ── Config ────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
    cp "$REPO_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"
    chown root:"$SERVICE_USER" "$CONFIG_DIR/config.yaml"
    chmod 640 "$CONFIG_DIR/config.yaml"
    info config.copied "copied config.yaml to $CONFIG_DIR"
else
    info config.skipped "config.yaml already exists — skipping (diff manually if needed)"
fi

if [[ ! -f "$CONFIG_DIR/litellm.env" ]]; then
    MASTER_KEY="sk-litellm-$(openssl rand -hex 16)"
    cat > "$CONFIG_DIR/litellm.env" << EOF
# LiteLLM API keys — chmod 600, never commit this file.
LITELLM_MASTER_KEY=$MASTER_KEY
GEMINI_API_KEY=
RUNPOD_API_KEY=
# ANTHROPIC_API_KEY=  # only needed if config.yaml's claude-* entries are
# switched away from the local claude-cli-server shim to the real API —
# see README.md's Requirements/Installation sections.
EOF
    chmod 600 "$CONFIG_DIR/litellm.env"
    # Never echo the key value itself — point at where to read it instead.
    # (2026-08-01 fleet audit: this line used to print the freshly generated
    # LITELLM_MASTER_KEY to stdout, persisting it into any tee'd install log
    # or terminal scrollback.)
    info secrets.generated "generated $CONFIG_DIR/litellm.env — read the master key with: sudo grep '^LITELLM_MASTER_KEY=' $CONFIG_DIR/litellm.env"
    info secrets.incomplete "fill in GEMINI_API_KEY and RUNPOD_API_KEY before starting (ANTHROPIC_API_KEY only needed if you switch claude-* off the local shim — see README)"
else
    info secrets.exists "litellm.env already exists — not overwriting"
fi

# ── Systemd service ───────────────────────────────────────────────────────────
cp "$REPO_DIR/systemd/litellm.service" /etc/systemd/system/litellm.service
systemctl daemon-reload
systemctl enable litellm.service
info service.installed "service installed and enabled"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<this machine LAN IP>}"

echo ""
echo "LiteLLM proxy installed on port $PORT"
echo ""
echo "  1. Add your API keys to $CONFIG_DIR/litellm.env"
echo "  2. sudo systemctl start litellm"
echo "  3. sudo systemctl status litellm"
echo ""
echo "  Endpoint: http://$IP:$PORT"
