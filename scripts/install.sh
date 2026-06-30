#!/usr/bin/env bash
# Install LiteLLM proxy as a systemd service under a dedicated service user.
# Run as root on the target machine.
set -euo pipefail

VENV=/opt/litellm/venv
CONFIG_DIR=/etc/litellm
DATA_DIR=/var/lib/litellm
SERVICE_USER=litellm
PORT=4000

info()  { echo "[install] $*"; }
die()   { echo "[install] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
command -v python3 >/dev/null || die "python3 not found"

# ── Service user ──────────────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" -m "$SERVICE_USER"
    info "created service user $SERVICE_USER"
else
    info "service user $SERVICE_USER already exists"
fi

# ── Directories ───────────────────────────────────────────────────────────────
mkdir -p /opt/litellm "$CONFIG_DIR" "$DATA_DIR"
chown "$SERVICE_USER:$SERVICE_USER" /opt/litellm "$DATA_DIR"
chown root:"$SERVICE_USER" "$CONFIG_DIR"
chmod 750 "$CONFIG_DIR"   # litellm group can traverse; root:root locked

# ── Python venv + LiteLLM ─────────────────────────────────────────────────────
info "creating venv at $VENV ..."
sudo -u "$SERVICE_USER" python3 -m venv "$VENV"
info "installing litellm[proxy] ..."
sudo -u "$SERVICE_USER" "$VENV/bin/pip" install --quiet --upgrade pip
sudo -u "$SERVICE_USER" "$VENV/bin/pip" install --quiet 'litellm[proxy]'
LITELLM_VERSION=$("$VENV/bin/litellm" --version 2>/dev/null || echo "unknown")
info "installed litellm $LITELLM_VERSION"

# ── Config ────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
    cp "$REPO_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"
    chown root:"$SERVICE_USER" "$CONFIG_DIR/config.yaml"
    chmod 640 "$CONFIG_DIR/config.yaml"
    info "copied config.yaml to $CONFIG_DIR"
else
    info "config.yaml already exists — skipping (diff manually if needed)"
fi

if [[ ! -f "$CONFIG_DIR/litellm.env" ]]; then
    MASTER_KEY="sk-litellm-$(openssl rand -hex 16)"
    cat > "$CONFIG_DIR/litellm.env" << EOF
# LiteLLM API keys — chmod 600, never commit this file.
LITELLM_MASTER_KEY=$MASTER_KEY
GEMINI_API_KEY=
ANTHROPIC_API_KEY=
EOF
    chmod 600 "$CONFIG_DIR/litellm.env"
    info "generated litellm.env with master key $MASTER_KEY"
    info "  → fill in GEMINI_API_KEY and ANTHROPIC_API_KEY before starting"
else
    info "litellm.env already exists — not overwriting"
fi

# ── Systemd service ───────────────────────────────────────────────────────────
cp "$REPO_DIR/systemd/litellm.service" /etc/systemd/system/litellm.service
systemctl daemon-reload
systemctl enable litellm.service
info "service installed and enabled"

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  LiteLLM proxy installed on port $PORT                        │"
echo "│                                                             │"
echo "│  1. Add your API keys to $CONFIG_DIR/litellm.env      │"
echo "│  2. sudo systemctl start litellm                           │"
echo "│  3. sudo systemctl status litellm                          │"
echo "│                                                             │"
echo "│  Endpoint: http://$(hostname -I | awk '{print $1}'):$PORT                  │"
echo "└─────────────────────────────────────────────────────────────┘"
