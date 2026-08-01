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
- **Visibility**: every request, its outcome, latency, tokens, and spend are exported as Prometheus metrics (see Observability below) — one shared query plane instead of grepping a proxy's journal by hand.
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
- Keys never appear in `config.yaml`, the service unit, or logs (`redact_user_api_key_info: true`); prompt/response bodies never reach logs either (`turn_off_message_logging: true`)
- Internal master key gates access from services on the LAN; rotate by updating `litellm.env` and restarting

## Observability

This is a long-lived daemon already bound to `:4000`, so metrics are a native
scraped `/metrics` endpoint rather than the node-exporter textfile collector
(that lane is for one-shot systemd units with nothing listening at scrape
time — see home-infra `CONVENTIONS.md` §18). Enabled via
`litellm_settings.callbacks: [prometheus]` in `config.yaml`, backed by the
`prometheus_client` pip package (installed by `scripts/install.sh` /
`scripts/update.sh`).

```bash
curl -sH "Authorization: Bearer $LITELLM_MASTER_KEY" http://10.0.0.243:4000/metrics
```

`/metrics` sits behind the same master-key auth as every other route
(`require_auth_for_metrics_endpoint` defaults to `true` as of litellm 1.85+)
— a Prometheus scrape job needs that header, same as any other caller. The
scrape job itself lives in `home-infra`, not this repo.

Key series (see `config/config.yaml` for the full mapping):

| Series | Answers |
|---|---|
| `litellm_proxy_total_requests_metric{requested_model, status_code}` | requests by model and outcome |
| `litellm_deployment_successful_fallbacks{requested_model, fallback_model}` / `litellm_deployment_failed_fallbacks` | which requests got a *different* model than they asked for — the fallback/quality-degradation signal an HTTP 200 otherwise hides (e.g. `qwen72b` → `gemini-2.5-flash`, see `config.yaml`'s `fallbacks:` block) |
| `litellm_deployment_cooled_down` | a deployment (e.g. one RunPod pod) going into cooldown |
| `litellm_request_total_latency_metric`, `litellm_llm_api_latency_metric` | latency, end-to-end vs upstream-only |
| `litellm_input_tokens_metric`, `litellm_output_tokens_metric`, `litellm_spend_metric` | token and cost accounting per model, where the upstream response reports it |

**Logs**: `JSON_LOGS=True` + `LITELLM_LOG=INFO` (set in `systemd/litellm.service`)
push LiteLLM's own log output to stdout/journald as JSON instead of plain
text. This has open upstream bugs on some versions
(BerriAI/litellm#19036, #19410) — verify after any deploy with
`journalctl -u litellm -n 20 -o cat` and expect JSON objects, not plain
lines; if it's still plain text, that's a known, not silently-assumed, gap.
`turn_off_message_logging: true` (`config.yaml`) keeps full prompt/response
bodies out of logs regardless — this proxy carries every prompt in the lab,
so that stays on unconditionally.

There is no spend database — `database_url` was deliberately removed after
Incident 1 (see `.claude/skills/llm-gateway-failure-archaeology`) and
`/var/lib/litellm/litellm.db` does not exist. `litellm_spend_metric` above is
the real, current way to see cost by model.

## Port

Default: `4000`. Change `--port` in `systemd/litellm.service` and redeploy.
