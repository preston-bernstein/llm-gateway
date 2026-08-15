---
name: llm-gateway-diagnostics-and-tooling
description: >
  Runnable, read-only diagnostic scripts for the llm-gateway LiteLLM proxy (desktop
  "multimedia", 10.0.0.243:4000) plus interpretation guides and baseline numbers. Load this
  skill when you need to CHECK GATEWAY HEALTH, QUANTIFY errors in the litellm journal,
  DETECT CONFIG DRIFT between the repo and /etc/litellm/config.yaml, or TIME a single model
  call — i.e., whenever you are tempted to eyeball "does it work?" instead of measuring.
  Also load it before trusting any claim that a model "is served" — catalog presence and
  serveability are different things here. The scripts live in this skill's scripts/ dir and
  run from the Mac via `ssh desktop-agent`. For symptom-driven triage flow use
  llm-gateway-debugging-playbook; for pass/fail acceptance criteria use
  llm-gateway-validation-and-qa.
---

# llm-gateway diagnostics and tooling

Measure, don't eyeball. This skill ships four read-only scripts and tells you what their
output means. All facts date-stamped 2026-07-02 unless noted.

**Jargon (defined once):** *gateway* = the LiteLLM proxy systemd service `litellm` on the
desktop (`multimedia`, 10.0.0.243), port 4000. *Shim* = claude-cli-server, an
OpenAI-compatible wrapper around the `claude` CLI on 127.0.0.1:4002. *Broker* = the
resource-broker, a GPU arbiter fronting Ollama on 127.0.0.1:11435 (interactive lane)
and :11436 (batch lane) — never use raw Ollama :11434. *Drift* = the live
`/etc/litellm/config.yaml` differing from the repo's `config/config.yaml`.

## The scripts

All run FROM THE MAC. **The example invocations below are repo-root-relative — run them from
`/Users/prestonbernstein/dev/llm-gateway` (e.g. prefix with
`cd /Users/prestonbernstein/dev/llm-gateway &&`), or use the absolute path
`/Users/prestonbernstein/dev/llm-gateway/.claude/skills/llm-gateway-diagnostics-and-tooling/scripts/<name>.sh`.**
All use `ssh desktop-agent` (override host with
`GATEWAY_SSH_TARGET=<host>`). All are strictly read-only against infrastructure: they never
restart, write, or modify anything on the desktop. The LiteLLM master key is read only
inside the remote shell (`sudo grep` on `/etc/litellm/litellm.env`) and is never printed or
copied to the Mac.

| Script | What it measures | Cost |
|---|---|---|
| `scripts/gateway-health.sh` | 7 PASS/FAIL checks: litellm active, liveliness 200, /v1/models with auth + model count, shim active, shim :4002 models, broker lanes 11435/11436 | Free |
| `scripts/config-drift.sh` | Byte-level unified diff, live config vs repo config | Free |
| `scripts/log-triage.sh [WINDOW]` | Journal error lines bucketed: timeout / auth / rate-limit / conn-refused / other, with counts and one example each | Free |
| `scripts/smoke-model.sh <model> [prompt]` | One timed chat completion via :4000 — HTTP code, latency seconds, first 120 chars of content | Depends on model — see cost warning |

### gateway-health.sh

```bash
.claude/skills/llm-gateway-diagnostics-and-tooling/scripts/gateway-health.sh
```

Exit 0 = all pass; exit N = N checks failed; exit 99 = SSH unreachable.

Interpretation:

| Observation | Meaning |
|---|---|
| All 7 PASS | Stack healthy. Baseline model count: 10 (2026-07-02). |
| liveliness 200 but /v1/models non-200 | Auth layer problem, NOT liveness. Note: this deployment does NOT return 401 — no key → HTTP 500 "Internal server error"; wrong key → HTTP 400 `"No connected db."` (side effect of removing `database_url`; see llm-gateway-failure-archaeology Incident 1). |
| Model count ≠ 10 | Catalog changed. Diff against the golden inventory in llm-gateway-validation-and-qa; run config-drift.sh. |
| shim checks FAIL | claude-* routes will fail regardless of gateway health → llm-gateway-debugging-playbook, claude row. |
| Broker lane 000 | Broker down OR GPU yielded to gaming/Plex — NOT a gateway bug. Observed live 2026-07-02: `systemctl is-active resource-broker` = `active` while both lanes returned 000 for minutes, then the batch lane recovered on its own. `active` + 000 = yielded/queue-held, not crashed. Re-check later before escalating. |

### config-drift.sh

```bash
.claude/skills/llm-gateway-diagnostics-and-tooling/scripts/config-drift.sh
```

Exit 0 + `NO DRIFT` = identical. Exit 1 + diff = drift (`-` lines are LIVE-only, `+` lines
are REPO-only). Exit 2 = couldn't compare (ssh/repo path failure).

**Drift is EXPECTED as of 2026-07-02.** The known overlay is exactly three things: all
claude-* → `openai/` at `http://localhost:4002/v1`, live-only `claude-fable-5`, live
`request_timeout: 300` vs repo 120. A diff showing exactly that = known state. Anything
else = new, uninvestigated drift — stop and open llm-gateway-timeout-and-drift-campaign.
NEVER "fix" drift by running `scripts/update.sh`: it copies the repo config over live
unconditionally and would break all claude-* traffic (see llm-gateway-change-control).

### log-triage.sh

```bash
.claude/skills/llm-gateway-diagnostics-and-tooling/scripts/log-triage.sh "-24 hours"
```

Window = anything `journalctl --since` accepts. The scan runs entirely on the remote side
(the journal is huge — ~2.5M lines/24h measured 2026-07-02); only the summary crosses the
wire.

Interpretation:

| Bucket | Meaning |
|---|---|
| `timeout` > 0 | LiteLLM `request_timeout` fired, historically at exactly 300.0s on claude-*/:4002 calls (open Incident 6) → open llm-gateway-timeout-and-drift-campaign. |
| `auth` > 0 | Clients calling without/with wrong master key. Example seen 2026-07-02: "No api key passed in". Benign if it matches known probing; investigate unexpected sources. |
| `rate-limit` > 0 | Almost certainly Gemini free tier (billing OFF, quota-fragile — Incident 4). Do not retry-hammer; route bulk work LOCAL. |
| `conn-refused` > 0 | A backend (shim :4002 or broker lane) was down when a request arrived. Correlate with gateway-health.sh. |
| `other` | Read the example line. Python tracebacks accompany the buckets above; a burst of `other` with zero in named buckets = something new — read the journal directly. |

Baseline 2026-07-02 (6h window, after a morning of authoring/testing): timeout 0, auth 6,
other 102 (traceback lines from earlier APIConnectionError/timeout events). A NONZERO
baseline is normal here — compare trends, not absolutes.

### smoke-model.sh

```bash
.claude/skills/llm-gateway-diagnostics-and-tooling/scripts/smoke-model.sh ollama/batch/qwen3-vl:30b
.claude/skills/llm-gateway-diagnostics-and-tooling/scripts/smoke-model.sh claude-haiku-4-5   # sparingly!
```

Prints HTTP code, latency (curl `time_total`), content snippet. Exit 0 only on HTTP 200.

**Cost warning:** claude-* models route (live overlay) through the shim to Preston's SHARED
Claude subscription and legitimately take 60–120 s even for trivial prompts — one call to
answer a question, never a loop. gemini-* burns fragile free-tier quota. Repeated/cheap
smoke tests: use a local `ollama/*` model.

Latency envelopes (2026-07-02): local ollama ~seconds to ~1 min depending on GPU
contention and model load state (estimate, not measured); gemini ~1–5 s when quota allows
(estimate, not measured); claude-* 60–120 s floor (observed). Anything hitting exactly
300 s = LiteLLM timeout ceiling, not a slow success.

## Worked example — why you measure instead of eyeball

On 2026-07-02, `gateway-health.sh` showed 10/10 models in the catalog and all-green gateway
checks. `smoke-model.sh ollama/batch/qwen2.5:3b` then returned HTTP 500 in 43 s:
`OllamaException - model 'qwen2.5:3b' not found`. Direct broker query
(`/api/tags` on :11436) showed the Ollama instance serves: qwen3-vl:30b,
lightrag-llm:latest, qwen3:8b, qwen3:30b-a3b, qwen2.5vl:7b(-q8_0), bge-m3, 
mxbai-embed-large, nomic-embed-text — **no qwen2.5, no qwen2.5:3b, no qwen2.5:7b**.

**KNOWN DEFECT (2026-07-02, open):** 3 of the 4 `ollama/*` entries in the live gateway
catalog (`ollama/interactive/qwen2.5`, `ollama/batch/qwen2.5:3b`, `ollama/batch/qwen2.5:7b`)
point at Ollama models that are not pulled — they are listed but cannot serve. Only
`ollama/batch/qwen3-vl:30b` is real. Catalog presence ≠ serveability. Fix options (pull the
models, or re-point/remove the entries) go through llm-gateway-change-control; do not
silently edit the live config. Incident record: llm-gateway-failure-archaeology, Incident 8.

Manual one-liner to re-check what Ollama actually serves (via broker batch lane):

```bash
ssh desktop-agent "curl -s -m 20 http://127.0.0.1:11436/api/tags" | python3 -c 'import json,sys
for m in json.load(sys.stdin)["models"]: print(m["name"])'
```

## Manual fallbacks (when the scripts can't run)

```bash
# liveliness (no auth)
ssh desktop-agent "curl -s -o /dev/null -w '%{http_code}\n' -m 10 http://127.0.0.1:4000/health/liveliness"
# authed models list — key never leaves the remote shell
ssh desktop-agent 'KEY=$(sudo grep "^LITELLM_MASTER_KEY=" /etc/litellm/litellm.env | cut -d= -f2); curl -s -m 15 -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models' | python3 -m json.tool | grep '"id"'
# drift (from the repo root; '-' lines = live-only, '+' lines = repo-only, matching config-drift.sh)
ssh desktop-agent "sudo cat /etc/litellm/config.yaml" | diff -u - config/config.yaml
# raw journal errors
ssh desktop-agent "sudo journalctl -u litellm --since '-6 hours' --no-pager -o cat" | grep -iE 'error|exception' | tail -30
```

## When NOT to use this skill

- You have a SYMPTOM and want the triage decision tree → **llm-gateway-debugging-playbook**
  (it tells you which measurement to take first; this skill is the measuring instrument).
- You need pass/fail acceptance criteria after a change → **llm-gateway-validation-and-qa**
  (the post-change checklist calls these scripts).
- You want to understand what a config value does → **llm-gateway-config-and-flags**.
- You are about to change anything → **llm-gateway-change-control** first.
- You are working the timeout/drift problem end-to-end → **llm-gateway-timeout-and-drift-campaign**.

## Provenance and maintenance

Scripts authored and live-tested 2026-07-02 (read-only SSH; gateway-health, config-drift,
log-triage, and smoke-model all executed against the live stack; two bugs found in testing
were fixed the same day: ssh arg-flattening broke log-triage's window argument, and curl
failure paths double-printed `000` in gateway-health).

Re-verification one-liners for volatile facts:

- Scripts still pass syntax: `bash -n .claude/skills/llm-gateway-diagnostics-and-tooling/scripts/*.sh`
- Golden model count still 10: run `gateway-health.sh`, read check 3.
- Known drift still exactly 3 deltas: run `config-drift.sh`, compare against the list above.
- qwen2.5 catalog entries still dead (or fixed): run the `/api/tags` one-liner above and
  compare with `grep 'model: ollama/' config/config.yaml`.
- Journal baseline: `log-triage.sh "-24 hours"` and compare bucket counts to the 2026-07-02
  baseline in this file.
- Broker lane semantics (`active` but 000 = yielded): `ssh desktop-agent "systemctl is-active resource-broker; curl -s -o /dev/null -m 10 -w '%{http_code}\n' http://127.0.0.1:11435/api/tags"`
