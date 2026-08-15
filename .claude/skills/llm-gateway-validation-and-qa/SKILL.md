---
name: llm-gateway-validation-and-qa
description: >
  Validation and acceptance criteria for the llm-gateway LiteLLM proxy
  (desktop `multimedia`, 10.0.0.243:4000). Load this skill AFTER ANY change,
  deploy, restart, or live edit of the gateway; BEFORE declaring anything
  "working", "fixed", or "verified"; and whenever deciding whether the
  evidence in hand is sufficient to accept a change. It owns the evidence
  hierarchy (there is no test suite), THE post-change checklist (the single
  home for it — sibling skills point here), the golden model inventory,
  per-backend smoke tests with latency envelopes, the rule for adding new
  acceptance checks, and the cost-awareness table (which checks are free vs
  which burn Gemini quota or Preston's Claude subscription).
---

# llm-gateway validation and QA

What counts as evidence that the gateway works, and the acceptance bar for any
change. **This project has no test suite, no CI, and no automated checks of any
kind.** "Testing" is curl smoke checks plus `journalctl` — which means the
discipline in this file is the only thing standing between "I restarted it" and
"it works". Run the checklist. Every time.

Terms, defined once:

- **Gateway** — the LiteLLM proxy, a systemd service (`litellm.service`) on the
  desktop, one OpenAI-compatible endpoint on port 4000.
- **Master key** — `LITELLM_MASTER_KEY`, required for all API calls except the
  liveliness endpoint. Its value lives ONLY in `/etc/litellm/litellm.env` on
  the desktop (root-only, 600). Never print it, never copy it off the box —
  the commands below read it into a shell variable on the remote host.
- **Backend class** — one of the four upstream families the gateway fronts:
  gemini (Google API), claude-via-:4002 (local claude-cli-server shim wrapping
  Preston's Claude subscription), ollama-interactive (broker :11435),
  ollama-batch (broker :11436).
- **Drift** — the live `/etc/litellm/config.yaml` is intentionally ahead of the
  repo's `config/config.yaml` in 3 known ways (delta list:
  **llm-gateway-config-and-flags**, drift section). Never run
  `scripts/update.sh` while the drift is unreconciled — it clobbers the live
  config. Policy and remediation: **llm-gateway-change-control** and
  **llm-gateway-timeout-and-drift-campaign**.

All commands below run from the Mac via `ssh desktop-agent` (read-only unless
stated). They can be copy-pasted as written.

## The evidence hierarchy

Four tiers, weakest to strongest. Higher tiers assume the lower ones pass.
**"It returned something once" is not evidence** — each tier has explicit pass
criteria, and a claim of "working" must state which tier backs it.

| Tier | What it proves | What it does NOT prove |
|---|---|---|
| 1 — Service state | The process is up and not crash-looping | That it can serve a single request |
| 2 — Endpoint checks | The HTTP surface responds, auth works, the catalog is right | That any upstream backend is reachable |
| 3 — Functional smoke | Each backend class completes one real request end-to-end | Reliability under load or over time |
| 4 — Sustained evidence | No errors across a real usage window | Nothing — this is the top of the bar for this project |

### Tier 1 — service state

```bash
ssh desktop-agent 'systemctl is-active litellm && systemctl show litellm -p NRestarts'
```

**Pass:** first line `active`, second line `NRestarts=0`.

Restart-loop caveat: `NRestarts` counts *automatic* restarts (`Restart=always`,
`RestartSec=5`) and resets to 0 on a manual `systemctl restart`. So immediately
after a deliberate restart, `NRestarts=0` proves nothing yet. A broken config
loops roughly every 5–10 s — wait 60 s, re-run, and confirm `NRestarts` is
still 0. Cross-check with the journal:

```bash
ssh desktop-agent 'journalctl -u litellm --since "5 minutes ago" --no-pager | grep -c "Started"'
```

**Pass:** `0` (steady state) or `1` (you just restarted it). Anything higher =
restart loop → **llm-gateway-debugging-playbook**.

### Tier 2 — endpoint checks

Liveliness — no auth required:

```bash
ssh desktop-agent 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4000/health/liveliness'
```

**Pass:** `200`.

Model catalog — requires the master key (read into a variable on the box; the
value never leaves the remote shell):

```bash
ssh desktop-agent 'KEY=$(sudo grep -oP "(?<=^LITELLM_MASTER_KEY=).*" /etc/litellm/litellm.env); curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models' | python3 -c 'import sys,json; [print(m["id"]) for m in sorted(json.load(sys.stdin)["data"], key=lambda m: m["id"])]'
```

**Pass:** HTTP 200 (a JSON parse failure here usually means an auth-error
body — 500 "Internal server error" if no header was sent, 400 "No connected
db." if the key is wrong; check the key) AND the list matches the golden
inventory below, modulo changes you
deliberately just made. An unexpected missing or extra model is a fail even if
everything "responds fine" → check the drift diff, then
**llm-gateway-debugging-playbook**.

### Tier 3 — functional smoke (one per backend class)

One real chat completion per backend class. Pass criteria for EVERY smoke:
HTTP 200, non-empty `choices[0].message.content` that actually answers the
prompt, and latency inside the class envelope. A 200 with empty or garbage
content is a FAIL.

Template (swap the `model` value per the table):

```bash
ssh desktop-agent 'KEY=$(sudo grep -oP "(?<=^LITELLM_MASTER_KEY=).*" /etc/litellm/litellm.env); curl -s -m 320 -w "\nHTTP %{http_code} in %{time_total}s\n" -X POST http://127.0.0.1:4000/v1/chat/completions -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "{\"model\":\"MODEL_NAME_HERE\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK\"}],\"max_tokens\":16}"'
```

| Backend class | Smoke model | Expected latency | Expected outcome and caveats (2026-07-02) |
|---|---|---|---|
| ollama (broker batch lane) | `ollama/batch/qwen3-vl:30b` — **the ONLY serveable `ollama/*` entry** (see the dead-entries caveat below) | seconds to ~1 min (estimate, not measured); can queue if GPU busy (gaming/Plex share it; broker arbitrates), and a cold model load adds tens of seconds | 200 + "OK". Slow ≠ broken here — check broker queueing before blaming the gateway |
| gemini | `gemini-2.5-flash` | ~1–5 s when quota OK (estimate, not measured) | 200 + "OK", **or 429**: Gemini billing is OFF, free tier is quota-fragile (Incident 4). A 429 with a quota message is an *upstream quota* signal, not a gateway failure — the gateway routing still counts as proven. A connection error or 500 is a gateway-side fail |
| claude-via-:4002 | `claude-haiku-4-5` | **60–120 s even for a trivial prompt** (CLI shim overhead; observed 2026-07-02) | 200 + "OK". **Every call consumes Preston's shared Claude subscription** (same account as his live Claude Code sessions) — smoke ONE model from this class, once, and only when the class is in scope (see cost table). Known open issue: calls can sit the full 300 s LiteLLM timeout and die with `APITimeoutError` (Incident 6, OPEN) — that is a pre-existing failure, not necessarily your regression |

Class caveats:

- **Dead ollama catalog entries (KNOWN DEFECT, open, 2026-07-02):**
  `ollama/interactive/qwen2.5`, `ollama/batch/qwen2.5:3b`, and
  `ollama/batch/qwen2.5:7b` sit in the catalog but their backing models are
  NOT pulled on the Ollama instance — smoking them returns HTTP 500
  `model '<name>' not found` on a perfectly HEALTHY gateway. Do not use them
  as smokes, and do not chase that 500 as a regression. Catalog presence ≠
  serveability — details and the `/api/tags` re-check one-liner:
  **llm-gateway-diagnostics-and-tooling**; incident record:
  **llm-gateway-failure-archaeology** Incident 8.
- `claude-fable-5` is served by the shim's substring mapping as **sonnet**
  ("fable" is not a CLI alias in the shim). A passing smoke of
  `claude-fable-5` proves the route is wired; it does NOT prove a Fable model
  answered. Do not use it as the class smoke.
- A single passing smoke certifies the route is *wired end-to-end today*. It
  says nothing about reliability under real load — that is tier 4.

### Tier 4 — sustained evidence

No gateway-side errors in the journal over an agreed window. Default window:
24 hours after the change, or one full run of a real consuming workload,
whichever comes first — agree the window before starting, don't declare it
retroactively.

```bash
ssh desktop-agent 'journalctl -u litellm --since "24 hours ago" --no-pager | grep -iE "APITimeoutError|APIConnectionError|Traceback" | wc -l'
```

**Pass:** `0` for the backend classes your change touches. To inspect matches
(redact any Authorization headers before quoting logs anywhere):

```bash
ssh desktop-agent 'journalctl -u litellm --since "24 hours ago" --no-pager | grep -iE "APITimeoutError|APIConnectionError" | tail -20'
```

**Known standing failure (2026-07-02):** the journal is NOT clean today —
repeated `APITimeoutError` / `APIConnectionError` on the claude-*-via-:4002
path (cluster ~08:01–09:22 on 2026-07-02; 117 APITimeoutError-matching lines
over the preceding 48 h when verified, ~5 lines per event ≈ 24 events). This
is Incident 6 (OPEN — three misaligned timeout
layers; see **llm-gateway-config-and-flags** for the layer table,
**llm-gateway-failure-archaeology** for the story). Interpretation rule: claude
class errors of this shape are the known baseline, not automatically your
regression; NEW errors on gemini or ollama classes, or a new error shape on
claude, ARE yours to explain.

## THE post-change checklist

This is the single home of the checklist. Run it after **any** config change,
deploy, restart, or live edit — no exceptions, no matter how trivial the change
felt. Ordered cheapest-first so a fail stops you before you spend quota or
subscription calls. On any mismatch: stop, do not proceed to the next step, go
to **llm-gateway-debugging-playbook**.

| # | Step | Command | Expected | On mismatch |
|---|---|---|---|---|
| 1 | Service active | `ssh desktop-agent 'systemctl is-active litellm'` | `active` | Debugging playbook (service-down branch) |
| 2 | No restart loop | wait 60 s after any restart, then `ssh desktop-agent 'systemctl show litellm -p NRestarts'` | `NRestarts=0` | Config likely broken (Incident 1 shape) → debugging playbook; check `journalctl -u litellm -n 50` |
| 3 | Liveliness | `ssh desktop-agent 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4000/health/liveliness'` | `200` | Debugging playbook |
| 4 | Catalog | the `/v1/models` command from tier 2 | 200 + exactly the golden inventory (± your deliberate change) | Wrong catalog = wrong config file loaded or clobbered → step 5, then debugging playbook |
| 5 | **Drift check (standing step)** | **command block A below** (or run `config-drift.sh` from **llm-gateway-diagnostics-and-tooling**) | Non-empty, showing ONLY the 3 known intentional deltas (delta list: **llm-gateway-config-and-flags**) plus your deliberate change | **Empty diff is NOT safe while the overlay is active** — it means the live config was clobbered back to repo (update.sh trap — claude-* now on a credit-less API key): restore the overlay from the newest sane backup FIRST, per **llm-gateway-timeout-and-drift-campaign** Phase 0.3. Unexplained extra diff = investigate before anything else. Both → **llm-gateway-change-control** + debugging playbook |
| 6 | Smoke: ollama class (free) | tier 3 template with `ollama/batch/qwen3-vl:30b` — the ONLY serveable ollama entry (dead-entries caveat in tier 3) | 200 + "OK" | HTTP 500 `model not found` on the three dead `qwen2.5*` entries is the known defect (Incident 8), not your regression; other failures → debugging playbook (broker/GPU-contention branch first) |
| 7 | Smoke: gemini (quota) | tier 3 template with `gemini-2.5-flash` | 200 + "OK", or 429-with-quota-message (acceptable — upstream quota, route proven) | Connection error / 500 → debugging playbook |
| 8 | Smoke: claude (subscription — only if in scope) | tier 3 template with `claude-haiku-4-5`, expect 60–120 s | 200 + "OK" | Timeout at ~300 s = known Incident 6 shape; other failures → debugging playbook |
| 9 | Journal scan | **command block B below** | Nothing new attributable to your change | Debugging playbook |
| 10 | Tier 4 window | agree a window (default 24 h / one real workload run); re-run the tier 4 scan at its end | 0 new errors on touched classes | Debugging playbook; the change is not "done" until this passes |

**Command block A — drift check (step 5).** Run from the repo root on the
Mac. The pipe and the diff run LOCALLY — never put this pipeline inside the
ssh quotes (the remote host has no `config/config.yaml`). Reading the output:
`-` lines are LIVE-only, `+` lines are REPO-only (same orientation as
`config-drift.sh`):

```bash
cd /Users/prestonbernstein/dev/llm-gateway
ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - config/config.yaml
```

**Command block B — journal scan (step 9):**

```bash
ssh desktop-agent 'journalctl -u litellm --since "10 minutes ago" --no-pager | grep -iE "error|traceback" | head -20'
```

Scope rule for steps 7–8: run them when the change could plausibly affect that
backend class (any config/deploy/restart affects ALL classes — so a full deploy
runs everything), and for any full "the gateway works" certification. A
live-edit that only touched an ollama entry may skip step 8 — say so explicitly
when reporting results ("verified through tier 3 except claude class, out of
scope"). Never skip silently.

Steps 1–6 and 9 are free — there is no excuse for skipping them, ever.

## Golden inventory — certified known-good snapshot

**Snapshot taken 2026-07-02. This WILL drift — regenerate before relying on it
(command in Provenance). A stale golden list that fails step 4 may mean the
list is old, not that the gateway is broken: regenerate first, then compare
against the last deliberate change.**

| Fact | Certified value (2026-07-02) |
|---|---|
| Service | `litellm.service` active, `NRestarts=0` |
| LiteLLM version | 1.90.1 (either works: `/opt/litellm/venv/bin/litellm --version` prints `LiteLLM: Current Version = 1.90.1`, or `/opt/litellm/venv/bin/pip show litellm`) |
| Liveliness | `GET /health/liveliness` → 200, no auth |
| `/v1/models` catalog (10 models) | `claude-fable-5`, `claude-haiku-4-5`, `claude-opus-4-8`, `claude-sonnet-4-6`, `gemini-2.5-flash`, `gemini-2.5-pro`, `ollama/batch/qwen2.5:3b`, `ollama/batch/qwen2.5:7b`, `ollama/batch/qwen3-vl:30b`, `ollama/interactive/qwen2.5`. **Caveat: catalog presence ≠ serveability** — 3 of the 4 `ollama/*` entries (`ollama/interactive/qwen2.5`, `ollama/batch/qwen2.5:3b`, `ollama/batch/qwen2.5:7b`) are cataloged but their backing models are not pulled; calling them returns HTTP 500 (known defect 2026-07-02 — **llm-gateway-diagnostics-and-tooling**, Incident 8 in **llm-gateway-failure-archaeology**). Only `ollama/batch/qwen3-vl:30b` actually serves |
| `/var/lib/litellm/` | No `litellm.db`, no spend database — only the service user's home-dir skeleton dotfiles (`.bashrc`, `.profile`, `.cache/`, etc.). **This is expected, not a bug**: `database_url` was removed in Incident 1 and spend logging does not exist. README's spend-tracking section still claims otherwise (stale — see **llm-gateway-change-control**, docs-of-record) |
| Journal | NOT clean — known claude-class `APITimeoutError` baseline (Incident 6, OPEN) |

## Adding a new acceptance check

Where things go — one home per artifact:

1. **The check's place in the acceptance bar** → extend the checklist table in
   THIS file (this skill is the checklist's only home; siblings link here).
   State the step's expected output and its cost class (free / quota /
   subscription), and slot it in cost order.
2. **Any script or tooling that implements the check** →
   **llm-gateway-diagnostics-and-tooling**. This file carries only the
   copy-pasteable one-liners; anything longer than a one-liner becomes a script
   there and gets referenced here by name.
3. **Rule: every new `model_list` entry ships with its smoke-test line.** A
   change that adds a model to `config/config.yaml` (or the live overlay) is
   incomplete until the tier 3 table above has a row (or an updated row) naming
   the model, its backend class, its latency envelope, and its cost class —
   same change, not a follow-up. This also updates the golden inventory
   snapshot (regenerate, re-date-stamp).
4. Editing this file is a change like any other: it goes through
   **llm-gateway-change-control** (see its `.claude/skills/` change class) and
   is committed attributed to Preston only. Note: the skills document the live
   overlay — whether `.claude/skills/` is ever pushed to the PUBLIC remote is
   an OPEN decision reserved for Preston; commit locally if instructed, do NOT
   push without his sign-off.

## Anti-eyeball discipline

- **Never judge "seems fine" from one manual curl.** One curl is tier-3-of-one:
  it exercises one model, one backend, one moment. Incidents 1 and 2 were both
  invisible until start/verify time; Incident 6 passes single smokes and still
  kills real workloads at 300 s. Run the checklist.
- **Name your tier.** Every "it works" report states the highest tier verified
  and any skipped steps. "Verified: tiers 1–3, claude class skipped (out of
  scope), tier 4 window ends 2026-07-03 14:00" is a report. "Restarted it and
  it looks fine" is not.
- **Spend consciously.** Cost classes:

| Cost class | Checks | Rule |
|---|---|---|
| Free | `systemctl` state, `NRestarts`, liveliness, `/v1/models`, journal scans, drift diff, ollama smokes (GPU contention is the only cost — the broker queues, nothing is billed) | Run always, run repeatedly, no hesitation |
| Quota | gemini smoke (free tier, billing OFF, 429-fragile under any bulk use) | One smoke per verification round; never loop it; a 429 is data, not an invitation to retry until 200 |
| Subscription | claude-* smoke via :4002 (each call burns 60–120 s and a slice of Preston's shared Claude account — the same account running his live Claude Code sessions; bulk use self-rate-limits it) | One model, one call, only when the class is in scope. Never use claude-* for repeated verification loops — if you need iteration, iterate on an ollama class and finish with a single claude confirmation |

- Ordering is the enforcement: the checklist runs free checks first so most
  failures cost nothing to find.

## When NOT to use this skill

- The gateway is failing and you need symptom-driven triage → **llm-gateway-debugging-playbook** (this skill defines pass/fail; that one owns what-to-do-when-fail)
- You are about to MAKE a change (classification, diff gate, backup, approval) → **llm-gateway-change-control**
- Deploy/restart/install mechanics themselves → **llm-gateway-install-and-operate**
- Writing or housing measurement/diagnostic scripts → **llm-gateway-diagnostics-and-tooling**
- What a config flag or timeout layer means → **llm-gateway-config-and-flags**
- Which model/tier a workload should use → **litellm-routing-reference**
- Full incident narratives (Incidents 1–8 cited above) → **llm-gateway-failure-archaeology**
- Drift remediation options and the timeout campaign → **llm-gateway-timeout-and-drift-campaign**
- System boundaries and ownership → **llm-gateway-architecture-contract**
- Future/experimental ideas → **llm-gateway-research-frontier**

## Provenance and maintenance

All live facts verified 2026-07-02 via read-only SSH (`ssh desktop-agent`) and
direct repo reads; repo facts verified against
`/Users/prestonbernstein/dev/llm-gateway`. Volatile facts are date-stamped
inline. Re-verify with:

- **Regenerate the golden model list** (do this first whenever step 4 surprises you): `ssh desktop-agent 'KEY=$(sudo grep -oP "(?<=^LITELLM_MASTER_KEY=).*" /etc/litellm/litellm.env); curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models' | python3 -c 'import sys,json; [print(m["id"]) for m in sorted(json.load(sys.stdin)["data"], key=lambda m: m["id"])]'`
- Service + restart count: `ssh desktop-agent 'systemctl is-active litellm && systemctl show litellm -p NRestarts'`
- LiteLLM version: `ssh desktop-agent '/opt/litellm/venv/bin/pip show litellm | grep -i ^version'`
- Liveliness: `ssh desktop-agent 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4000/health/liveliness'`
- No spend DB still expected: `ssh desktop-agent 'sudo ls -A /var/lib/litellm/'` (skeleton dotfiles only, no `litellm.db`)
- Drift still present: `cd /Users/prestonbernstein/dev/llm-gateway && ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - config/config.yaml` (`-` = live-only, `+` = repo-only)
- Ollama entries still dead (Incident 8): `ssh desktop-agent 'curl -s -m 20 http://127.0.0.1:11436/api/tags'` — look for qwen2.5 names in the served list
- Incident 6 baseline still dirty: `ssh desktop-agent 'journalctl -u litellm --since "24 hours ago" --no-pager | grep -ciE "APITimeoutError|APIConnectionError"'`
- Fable→sonnet shim mapping still in place: `ssh desktop-agent 'grep -n fable /opt/claude-cli-server/server.py'`

If any re-verification contradicts this file, update the file (through change
control) rather than trusting the snapshot.
