# llm-gateway

A self-hosted [LiteLLM](https://github.com/BerriAI/litellm) proxy that runs as a hardened systemd service on a Linux machine. Acts as a unified OpenAI-compatible gateway in front of multiple AI providers and local Ollama models — one endpoint, one place for API keys, one visibility plane.

## Architecture

```
                        ┌─────────────────────────────┐
                        │        llm-gateway          │
  services  ──────────▶│   LiteLLM proxy :4000       │──▶  Gemini API
  (OpenAI format)       │   /etc/litellm/config.yaml  │──▶  Anthropic API
                        │   /etc/litellm/litellm.env  │──▶  Ollama (local, :11435/:11436)
                        └─────────────────────────────┘
```

**Why a proxy instead of direct API calls per service?**

- **Key management**: API keys live in one env file (`/etc/litellm/litellm.env`). Services carry no credentials — they call localhost with an internal master key.
- **Visibility**: Every call (local and cloud) is logged to a SQLite DB with model, tokens, latency, and cost. One `SELECT` to see what ran and what it cost.
- **Provider abstraction**: Swap Gemini Flash for something better without touching any service. Change the model alias in `config.yaml`, restart, done.
- **FrugalGPT cascade compatibility**: Services implement L1 → L2 → L3 escalation logic; the gateway handles routing each tier to the right backend, including auth format differences (Anthropic native vs OpenAI-compat).

## Requirements

- Linux with systemd
- Python 3.10+
- `openssl` (for master key generation in install script)
- Root access to install the service

## Installation

```bash
git clone https://github.com/preston-bernstein/llm-gateway
cd llm-gateway
sudo bash scripts/install.sh
```

The install script:
1. Creates a `litellm` service user (nologin, no shell)
2. Installs LiteLLM into `/opt/litellm/venv/`
3. Copies `config/config.yaml` to `/etc/litellm/`
4. Generates `/etc/litellm/litellm.env` with a random master key
5. Installs and enables the systemd service

Then add your API keys:

```bash
sudo nano /etc/litellm/litellm.env
# Fill in GEMINI_API_KEY and/or ANTHROPIC_API_KEY
```

Start it:

```bash
sudo systemctl start litellm
sudo systemctl status litellm
```

## Configuration

`config/config.yaml` defines which models are served and where they route. **No secrets belong here** — use `os.environ/<VAR>` references; keys are injected via the `EnvironmentFile`.

See `config/config.example.yaml` for a minimal starting point.

## Updating

```bash
git pull
sudo bash scripts/update.sh
```

This upgrades the `litellm` package, syncs `config.yaml`, and restarts the service.

## Usage

Any service that speaks OpenAI-compatible API can point at the gateway:

```
OPENAI_API_BASE=http://10.0.0.243:4000
OPENAI_API_KEY=<LITELLM_MASTER_KEY>
```

Or with the Python SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://10.0.0.243:4000",
    api_key="sk-litellm-...",
)

response = client.chat.completions.create(
    model="gemini-2.5-flash",
    messages=[{"role": "user", "content": "Hello"}],
)
```

Model names are whatever you define in `config.yaml`. The gateway handles translating to provider-specific formats (Anthropic native auth, Ollama `/api/generate`, etc.).

## Security

- Service runs as `litellm` (nologin system user)
- `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`
- `/etc/litellm/` is `chmod 750` root:root — service reads env via `EnvironmentFile`, not filesystem access
- Keys never appear in `config.yaml`, the service unit, or logs (`redact_user_api_key_info: true`)
- Internal master key gates access from services on the LAN; rotate by updating `litellm.env` and restarting

## Spend tracking

LiteLLM logs every request to `/var/lib/litellm/litellm.db`. To see spend by model:

```bash
sqlite3 /var/lib/litellm/litellm.db \
  "SELECT model, COUNT(*) calls, SUM(spend) total_usd FROM litellm_spendlogs GROUP BY model ORDER BY total_usd DESC;"
```

## Port

Default: `4000`. Change `--port` in `systemd/litellm.service` and redeploy.
