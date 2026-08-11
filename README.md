# llm-gateway

llm-gateway is a self-hosted proxy built on [LiteLLM](https://github.com/BerriAI/litellm), running as a hardened systemd service on a Linux machine.

It gives your services one OpenAI-compatible endpoint in front of the Gemini API, Claude (via a local subscription-based CLI shim, not the billed Anthropic API — see Architecture below), and local Ollama models. That gets you:

- **One endpoint** every service calls, instead of each service wiring up its own provider.
- **One place for API keys** — services never hold a provider credential themselves.
- **One visibility plane** — every request's outcome, latency, and cost show up in one place.

## Architecture

```
                        ┌─────────────────────────────┐
                        │        llm-gateway          │
  services  ──────────▶│   LiteLLM proxy :4000       │──▶  Gemini API
  (OpenAI format)       │   /etc/litellm/config.yaml  │──▶  claude-cli-server :4002 (Claude subscription)
                        │   /etc/litellm/litellm.env  │──▶  Ollama (local, via broker :11435/:11436)
                        └─────────────────────────────┘
```

**Claude models run through a subscription shim, not the API.** The `claude-*` entries in `config.yaml` route to `claude-cli-server` (`http://localhost:4002`), a separate local service that wraps the `claude` CLI (`claude -p --dangerously-skip-permissions`) and authenticates with an existing Claude subscription instead of billed API usage. It's a hard runtime dependency for every `claude-*` model — if it isn't running, those requests fail even though the gateway itself is healthy. `config/config.example.yaml` shows the alternative for anyone without this shim set up: point `claude-*` entries directly at the real Anthropic API with `ANTHROPIC_API_KEY`.

**Why use a proxy instead of calling each provider's API directly?**

- **Key management**: API keys live in one env file, `/etc/litellm/litellm.env`. Services carry no credentials of their own — they call `localhost` with an internal master key instead.
- **Visibility**: every request — its outcome, latency, tokens, and spend — is exported as Prometheus metrics (see Observability below). That gives you one shared place to query, instead of grepping through a proxy's log by hand.
- **Provider abstraction**: to swap Gemini Flash for a better model, change the model alias in `config.yaml` and restart — no service code changes needed.
- **FrugalGPT cascade compatibility**: FrugalGPT is a cost-saving strategy — try a cheap model first, and escalate to a pricier one only if it fails a quality check. Services implement that escalation logic tier by tier; the gateway routes each tier's call to the right backend, whatever protocol or endpoint that backend actually needs — Gemini's native format, the local Claude shim, or Ollama's own API.

## Requirements

- Linux with systemd
- Python 3.10+
- `openssl` (master key generation in install script)
- `curl` (health check in update script)
- Root access to install the service
- For `claude-*` models: `claude-cli-server` running locally on port 4002 (see Architecture above). Not needed if you swap those entries for direct Anthropic API calls instead.

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
# Fill in GEMINI_API_KEY and RUNPOD_API_KEY
```

`claude-*` models need no key here — they route through `claude-cli-server` (see Architecture above). If you're not running that shim and want the real Anthropic API instead, edit `config.yaml`'s `claude-*` entries to use `anthropic/<model>` + `api_key: os.environ/ANTHROPIC_API_KEY` (see `config/config.example.yaml`) and add `ANTHROPIC_API_KEY=` to `litellm.env` yourself.

Start it:

```bash
sudo systemctl start litellm
sudo systemctl status litellm
```

## Configuration

`config/config.yaml` lists which models the gateway serves and where each one routes. **Never put secrets in this file.** Instead, reference an environment variable with `os.environ/<VAR>` — LiteLLM reads the real value from `/etc/litellm/litellm.env` at startup, injected through the systemd `EnvironmentFile` directive.

See `config/config.example.yaml` for a minimal starting point.

## Updating

```bash
git pull
sudo bash scripts/update.sh
```

This upgrades the `litellm` package, syncs `config.yaml`, and restarts the service.

## Usage

Any service that speaks the OpenAI-compatible API format can call the gateway directly:

```
OPENAI_API_BASE=http://<gateway-host>:4000
OPENAI_API_KEY=<LITELLM_MASTER_KEY>
```

Or with the Python SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://<gateway-host>:4000",
    api_key="sk-litellm-...",
)

response = client.chat.completions.create(
    model="gemini-2.5-flash",
    messages=[{"role": "user", "content": "Hello"}],
)
```

Model names are whatever you define in `config.yaml`. The gateway translates each request into the format its provider expects (the claude-cli-server shim's OpenAI-compatible interface, Ollama's `/api/generate`, and so on).

## Security

- The service runs as `litellm`, a nologin system user — it can't log in interactively, it only runs the proxy process.
- systemd options `ProtectSystem=strict`, `ProtectHome=true`, and `PrivateTmp=true` lock the service's filesystem access down to what it needs.
- `/etc/litellm/` is `chmod 750`, owned by `root:litellm` so the service group can read its own config. The service reads secrets through the systemd `EnvironmentFile` directive, not by opening files itself.
- Keys never appear in `config.yaml`, the systemd unit, or logs: `redact_user_api_key_info: true` strips them from logs, and `turn_off_message_logging: true` keeps prompt and response bodies out of logs too.
- An internal master key gates every request from services on the LAN. To rotate it, update `litellm.env` and restart the service.

## Observability

This is a long-lived daemon already listening on `:4000`, so it exposes metrics through its own `/metrics` endpoint rather than through the node-exporter textfile collector (that collector is meant for one-shot systemd units that have nothing listening at scrape time — see home-infra's `CONVENTIONS.md` §18). Metrics are turned on with `litellm_settings.callbacks: [prometheus]` in `config.yaml`, backed by the `prometheus_client` pip package, which `scripts/install.sh` and `scripts/update.sh` install automatically.

```bash
curl -sH "Authorization: Bearer $LITELLM_MASTER_KEY" http://<gateway-host>:4000/metrics
```

`/metrics` sits behind the same master-key check as every other route (as of litellm 1.85+, `require_auth_for_metrics_endpoint` defaults to `true`). A Prometheus scrape job needs to send that same header, like any other caller. The scrape job itself lives in the `home-infra` repo, not this one.

Key metric series (see `config/config.yaml` for the full mapping):

| Series | Answers |
|---|---|
| `litellm_proxy_total_requests_metric{requested_model, status_code}` | requests by model and outcome |
| `litellm_deployment_successful_fallbacks{requested_model, fallback_model}` / `litellm_deployment_failed_fallbacks` | which requests got a *different* model than they asked for. A fallback still returns HTTP 200, so this metric is the only way to see that quality silently degraded (e.g. `qwen72b` falling back to `gemini-2.5-flash`; see the `fallbacks:` block in `config.yaml`) |
| `litellm_deployment_cooled_down` | a deployment (e.g. one RunPod pod) has gone into cooldown |
| `litellm_request_total_latency_metric`, `litellm_llm_api_latency_metric` | latency: end-to-end vs. upstream-only |
| `litellm_input_tokens_metric`, `litellm_output_tokens_metric`, `litellm_spend_metric` | tokens and cost per model, wherever the upstream provider reports it |

**Logs**: setting `JSON_LOGS=True` and `LITELLM_LOG=INFO` (in `systemd/litellm.service`) makes LiteLLM write its logs to stdout/journald as JSON instead of plain text. Some LiteLLM versions have open bugs where this doesn't happen (see upstream issues BerriAI/litellm#19036 and #19410) — after any deploy, run `journalctl -u litellm -n 20 -o cat` and confirm you see JSON objects, not plain lines. If you still see plain text, that's this known gap, not a new bug. Separately, `turn_off_message_logging: true` in `config.yaml` always keeps full prompt and response bodies out of the logs — this proxy carries every prompt used in the lab, so that setting stays on no matter what.

There is no spend database. `database_url` was deliberately removed after Incident 1 (see `.claude/skills/llm-gateway-failure-archaeology` for that story), so `/var/lib/litellm/litellm.db` does not exist. Use `litellm_spend_metric`, above, to see real, current cost per model instead.

## Port

Default port: `4000`. To change it, edit `--port` in `systemd/litellm.service` and redeploy.
