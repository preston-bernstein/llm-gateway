---
name: llm-gateway-failure-archaeology
description: >
  Incident chronicle for the llm-gateway repo and its live deployment (LiteLLM
  proxy on 10.0.0.243:4000 plus the claude-cli-server shim on :4002). Load this
  skill when: (a) you are investigating a failure of the gateway or a claude-*/
  gemini-*/ollama-* model route and want to know whether it is a RECURRENCE of a
  known incident; (b) you are about to "fix" something in this repo or on the
  live box that looks obviously wrong (a missing database_url, odd permissions,
  a weirdly-named backup file, a config that differs from git) — it may be a
  deliberate scar from a past incident, and reverting it re-triggers the
  failure; (c) you are writing a postmortem or need the full
  symptom/root-cause/evidence/fix history of any past incident; (d) you need to
  APPEND a new incident to the chronicle. This skill is the single home for
  full incident narratives — sibling skills cite it, they do not retell.
---

# llm-gateway failure archaeology

This is the incident chronicle for the `llm-gateway` project: every
investigation, failure, and dead end since the project started (2026-06-30),
each told as **symptom → root cause → evidence → fix → current status**.
Full narratives live ONLY here. If you fixed or diagnosed something new,
append it using the template at the bottom.

All volatile facts below were verified **2026-07-02** (repo reads + read-only
SSH to the live host). Re-verify with the commands in each incident and in
"Provenance and maintenance" before acting on them.

## Terms used throughout (defined once)

| Term | Meaning |
|---|---|
| **the gateway** | LiteLLM proxy (`litellm.service`) on the home-lab desktop `multimedia` (10.0.0.243), port **4000**. One OpenAI-compatible endpoint fronting Gemini, Claude, and local Ollama models. Repo: `/Users/prestonbernstein/dev/llm-gateway` (public GitHub, `preston-bernstein/llm-gateway`). |
| **the shim** | `claude-cli-server`: `/opt/claude-cli-server/server.py` (FastAPI, ~186 lines) on `127.0.0.1:4002` on the same box. Wraps the `claude -p --dangerously-skip-permissions` CLI (Preston's Claude subscription) behind an OpenAI-compatible API. **Not in any git repo.** |
| **the broker** | `resource-broker` — all local Ollama inference goes through it: `:11435` interactive, `:11436` batch, `:11437/jobs` durable. Never raw Ollama `:11434`. |
| **the drift** | Live `/etc/litellm/config.yaml` is hand-edited AHEAD of the repo's `config/config.yaml`. See Incident 7. |
| **LightRAG** | The RAG service whose bulk entity-extraction workload drove Incidents 3–5. |
| **LiteLLM tier contract** | LOCAL (ollama/*) / FAST (gemini-2.5-flash) / MID / FRONTIER, per `ROUTING.md`. Services own cascade policy; the gateway owns only the model catalog. |
| **`ssh desktop-agent`** | Read-only-capable SSH alias to the live box (agent user, NOPASSWD sudo). All "live evidence" commands below assume it. |

---

## Incident 1 — `database_url` startup failure (2026-06-30) — fixed, with a live landmine

**Symptom.** Fresh install: the proxy failed to start at all. `litellm.service`
crash-looped instead of listening on :4000.

**Root cause.** The initial `config/config.yaml` contained
`database_url: "sqlite:////var/lib/litellm/litellm.db"` under
`general_settings`. LiteLLM's DB-backed spend logging requires the **prisma**
Python client (generate + migrate steps), which was never installed. With
`database_url` set and prisma absent, the proxy refuses to start.

**Fix.** Drop the `database_url` line entirely (no prisma, no DB, no spend
logging). Commit `27b1fa0` (2026-06-30, "fix: remove database_url, correct
/etc/litellm permissions").

**Evidence.**
```bash
git -C /Users/prestonbernstein/dev/llm-gateway show 27b1fa0   # message + diff removing the line
ssh desktop-agent 'sudo ls -la /var/lib/litellm/'             # no litellm.db — dir has only dotfiles
```

**Current status (2026-07-02).** Fixed in `config/config.yaml` — **but two
scars remain open**:

1. **Landmine:** `config/config.example.yaml` line 36 STILL carries
   `database_url: "sqlite:////var/lib/litellm/litellm.db"`. Anyone who copies
   the example verbatim reproduces this exact startup failure. Verify:
   `grep -n database_url /Users/prestonbernstein/dev/llm-gateway/config/config.example.yaml`
2. **Stale doc:** `README.md` § "Spend tracking" (lines ~109–116) claims every
   request is logged to `/var/lib/litellm/litellm.db` and shows a `sqlite3`
   spend query. **No spend/usage logging exists today.** The DB was never
   created.

If you hit "proxy won't start" after touching config: check for `database_url`
first. If you're tempted to "add back" spend tracking because the README
mentions it — that's this incident recurring; it needs prisma installed and a
migration, which is a change-control decision (see
`llm-gateway-change-control`), not a quick fix.

---

## Incident 2 — `/etc/litellm` permissions blocked the service user (2026-06-30) — fixed

**Symptom.** Proxy could not read its own config: the `litellm` service user
(nologin, created by `scripts/install.sh`) failed to open
`/etc/litellm/config.yaml`.

**Root cause.** `install.sh` originally left `/etc/litellm` as `root:root 750`
— the `litellm` user could neither traverse the directory nor read the file.

**Fix.** Same commit `27b1fa0`: directory `root:litellm 750`, `config.yaml`
`root:litellm 640`. Crucially, `litellm.env` (the secrets file) stays
**root-only 600** — the service user never reads it directly; systemd (running
as root) injects it via `EnvironmentFile=/etc/litellm/litellm.env` in
`systemd/litellm.service`. That split is deliberate: config readable by the
service group, secrets readable by root/systemd only.

**Evidence.**
```bash
git -C /Users/prestonbernstein/dev/llm-gateway show 27b1fa0   # install.sh/update.sh chown+chmod hunks
ssh desktop-agent 'sudo ls -la /etc/litellm/'
# expect: dir root:litellm 750; config.yaml root:litellm 640; litellm.env root:root 600
```

**Current status (2026-07-02).** Fixed and holding (verified live). Do NOT
"tidy" `litellm.env` to group-readable, and do not loosen the dir — the current
perms are the scar tissue. If a future LiteLLM feature needs the service user
to read something new under `/etc/litellm`, follow the same pattern:
`root:litellm 640`, never 644, never secrets.

---

## Incident 3 — shim argv-prompt 502s (2026-07-02) — fixed, but the fix is unversioned

**Symptom.** LightRAG extraction calls routed `claude-haiku-4-5 → gateway →
shim (:4002)` returned **502**. Only some prompts failed.

**Root cause.** The shim originally passed the user prompt to the `claude` CLI
as a **positional argv argument**. LightRAG prompts begin with `---Task---` —
the leading dashes were parsed by the CLI as flags, the CLI errored, the shim
surfaced 502. Any prompt starting with `-` would do it.

**Fix.** Feed the prompt via **STDIN** instead of argv: non-streaming path uses
`subprocess.run(cmd, input=prompt, ...)`; streaming path uses
`subprocess.Popen(cmd, stdin=subprocess.PIPE, ...)`.

**Evidence** (live box; the shim has no repo):
```bash
ssh desktop-agent 'sudo grep -n "input=prompt\|stdin=subprocess.PIPE" /opt/claude-cli-server/server.py'
# verified 2026-07-02: line 75 subprocess.run(..., input=prompt, ...); line 101 Popen(..., stdin=subprocess.PIPE, ...)
```

**Current status (2026-07-02).** Fixed in the live file. **Risk:** `/opt/claude-cli-server/server.py`
is under NO version control — no repo, no backup discipline. If the file is
lost or hand-edited badly, this fix (and the whole Claude route while the drift
overlay is active — Incident 7) evaporates silently. Bringing the shim under
change control is tracked in `llm-gateway-timeout-and-drift-campaign`. Related
known-weak point: the shim runs as `User=preston`, violating the house rule
that services run under dedicated nologin users — an open item; do not
"fix" it ad hoc (see `llm-gateway-change-control`).

---

## Incident 4 — Gemini free-tier quota wall (2026-07-01/02) — open constraint

**Symptom.** Bulk LightRAG extraction against `gemini-2.5-flash` (the FAST
tier) started returning **429 Too Many Requests** partway through runs.

**Root cause.** The Gemini account has **billing OFF** — free-tier
rate/quota limits. Not a gateway bug: the gateway faithfully relayed Google's
429s. Bulk workloads exhaust the free tier quickly.

**Fix.** None applied at the gateway. The workload moved off Gemini (first to
the shim — Incident 5 — then to local models).

**Evidence.** Historical (the 429s were observed during the runs; not
reproducible on demand without re-running bulk extraction, which you should
not do just to check). To see current Gemini errors if suspected recurring:
```bash
ssh desktop-agent 'sudo journalctl -u litellm --since "-2h" --no-pager | grep -i "429\|RESOURCE_EXHAUSTED\|RateLimit"'
```

**Current status (2026-07-02).** **Open constraint, by design for now:** the
FAST tier is quota-fragile for bulk work as long as billing stays off. Treat
`gemini-2.5-flash` as fine for interactive/low-volume escalation, unsuitable as
a bulk workhorse. Enabling billing is Preston's decision, not a maintainer fix.
Tier semantics live in `litellm-routing-reference`.

---

## Incident 5 — claude-cli bulk-extraction abandonment (2026-07-02) — resolved by rerouting; standing lesson

**Symptom.** After the Incident 3 STDIN fix, LightRAG extraction via
`claude-haiku-4-5 → :4002` *worked* — but each trivial call took **60–120
seconds**, the run self-rate-limited Preston's Claude account, and that account
is **shared with his live Claude Code sessions** (bulk runs degraded his own
interactive use).

**Root cause.** Not a bug — a capability mismatch. The shim shells out to the
`claude` CLI per request: full CLI startup + subscription-account rate limits.
It was never going to absorb a bulk pipeline.

**Fix (final configuration for that workload).** LightRAG's LLM moved to a
local `lightrag-llm` model served via the **broker batch lane :11436**. Bulk
extraction never touches the gateway's cloud/CLI routes anymore.

**Evidence.** Historical observation from the LightRAG saga (timings and
rate-limiting were observed live 2026-07-02; principal-verified). The
surviving artifact is the constraint itself: the shim's per-call latency is
easy to confirm with a single harmless probe if ever needed (one call, not a
loop).

**Current status (2026-07-02).** Resolved for LightRAG; the **lesson is
standing policy**: the LOCAL tier is the bulk workhorse; `:4002` (and thus all
live `claude-*` routes while the drift overlay is active — Incident 7) is
**low-volume only**. `ROUTING.md`'s "most calls never leave the free tier" is
enforced by economics and account safety, not just principle. If you are about
to point a batch job at any `claude-*` model on this gateway: stop, reread this
incident, use `ollama/batch/*` via the broker.

---

## Incident 6 — timeout stack mismatch (2026-07-02) — **OPEN**

**Symptom.** `journalctl -u litellm` on the morning of 2026-07-02 (error
cluster ~08:01–09:22) shows repeated `litellm.Timeout: APITimeoutError ...
timeout value=300.0, time taken=300.0 seconds` on `claude-*` calls (Model
Group `claude-haiku-4-5`, aiohttp `SocketTimeoutError` underneath) — requests
sat for the full LiteLLM timeout and died.

**Root cause (diagnosed, not yet fixed).** The timeout layers in the
`claude-*` path are **not aligned**. In brief (the canonical layer table
lives in `llm-gateway-config-and-flags`): LiteLLM `request_timeout` (live
**300** / repo **120** — part of the drift, Incident 7) → shim per-request
`timeout` body param (default **180**, passed down as the `subprocess.run`
timeout) → the streaming `Popen` path, which has **no timeout at all**.

A slow CLI call can outlive the shim's 180 s, or the shim can hold the socket
past LiteLLM's limit; either way LiteLLM kills the request at exactly its own
`request_timeout` while the CLI may still be burning subscription quota
underneath. The 2026-07-01 mitigation of raising live `request_timeout`
120→300 **already failed** — the journal shows hits at 300.0 s.

**Evidence** (reproduced firsthand 2026-07-02):
```bash
ssh desktop-agent 'sudo journalctl -u litellm --since "2026-07-02 09:00" --until "2026-07-02 09:30" --no-pager | grep -i timeout'
# shows: APITimeoutError ... timeout value=300.0, time taken=300.0 seconds (e.g. 09:00:41)
ssh desktop-agent 'sudo grep -n request_timeout /etc/litellm/config.yaml'          # live: 300
grep -n request_timeout /Users/prestonbernstein/dev/llm-gateway/config/config.yaml # repo: 120
ssh desktop-agent 'sudo grep -n "timeout" /opt/claude-cli-server/server.py'        # 600 signature default, 180 body default, Popen path none
```

**Fix.** None yet. Raising one layer in isolation is proven insufficient.

**Current status (2026-07-02).** **OPEN.** The canonical timeout-layer
reference table lives in `llm-gateway-config-and-flags`; the remediation plan
(aligning all layers, deciding budgets, bringing the shim under control) is
`llm-gateway-timeout-and-drift-campaign` — do not improvise a fix here. If you
see fresh 300.0 s APITimeoutErrors, it is THIS incident, still open, not a new
mystery.

---

## Incident 7 — the drift itself: live config ahead of the repo (2026-07-01/02) — **OPEN, standing hazard**

This one is not a single failure but the condition that makes several failures
possible.

**Symptom / condition.** Live `/etc/litellm/config.yaml` was hand-edited and
is AHEAD of the repo's `config/config.yaml` in 3 known ways (the enumerated,
maintained delta list lives in `llm-gateway-config-and-flags`, drift
section): claude-* → the shim at `:4002` with `api_key: "none"` (the repo's
`anthropic/` routing points at an API account that is **out of credits**);
live-only `claude-fable-5` (which the shim silently serves as sonnet); live
`request_timeout: 300` vs repo `120` (Incident 6 mitigation).

**Root cause.** Urgent live fixes (credits outage, timeout mitigation) were
applied directly on the box and never reconciled into git. Per the
coordinator (assumption-level): the :4002 routing is a **local overlay**;
whether it becomes canonical in the public repo is an OPEN decision — this
skill records the situation and must not decide repo policy.

**The standing clobber risk.** `scripts/update.sh` copies the repo config over
the live one **unconditionally**:
```bash
cp "$REPO_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"   # scripts/update.sh, no diff, no prompt
```
Running `sudo bash scripts/update.sh` today would silently revert all
`claude-*` traffic to API-key billing (**no credits → every claude-* call
fails**), drop `claude-fable-5`, and cut `request_timeout` back to 120. This is
the #1 live trap in the project. Do not run update.sh until the drift is
reconciled (decision menu: `llm-gateway-timeout-and-drift-campaign`).

**Mini-lesson: the `$(date +%s)` backup artifact.** `/etc/litellm/` contains
two manual backups: `config.yaml.bak.1782940343` (correct) and a file literally
named `config.yaml.bak.$(date +%s)` — a quoting mistake suppressed the command
substitution (full explanation of the trap:
`llm-gateway-install-and-operate` §3 step 2). Harmless but confusing; it is
also *evidence that live hand-edits happened* (backups exist precisely because
someone edited live). Don't delete these files casually — they are the only
pre-edit snapshots of the live config.

**Evidence** (all reproduced firsthand 2026-07-02):
```bash
ssh desktop-agent 'sudo ls -la /etc/litellm/'    # both .bak files visible, incl. the literal $(date +%s) name
ssh desktop-agent 'sudo grep -n "4002\|api_key: \"none\"\|claude-fable-5\|request_timeout" /etc/litellm/config.yaml'
grep -n "anthropic/\|request_timeout" /Users/prestonbernstein/dev/llm-gateway/config/config.yaml
sed -n '14,20p' /Users/prestonbernstein/dev/llm-gateway/scripts/update.sh   # the unconditional cp
```

**Current status (2026-07-02).** **OPEN.** Live overlay active and load-bearing;
update.sh remains armed. Any change to config, scripts, or the service goes
through `llm-gateway-change-control`; reconciliation options live in
`llm-gateway-timeout-and-drift-campaign`.

---

## Incident 8 — dead ollama catalog entries (2026-07-02) — **OPEN**

**Symptom.** Calls to 3 of the 4 `ollama/*` catalog entries fail with
**HTTP 500** `OllamaException - model '<name>' not found` — on a gateway
whose health checks are all green and whose `/v1/models` catalog lists all
four. Affected entries: `ollama/interactive/qwen2.5`,
`ollama/batch/qwen2.5:3b`, `ollama/batch/qwen2.5:7b`. Only
`ollama/batch/qwen3-vl:30b` serves.

**Root cause.** Catalog entries were added to config.yaml for Ollama models
that were never pulled on the Ollama instance behind the broker. Catalog
presence ≠ serveability: LiteLLM lists whatever `model_list` declares and
only discovers the missing model at call time.

**Evidence** (observed 2026-07-02: a `smoke-model.sh ollama/batch/qwen2.5:3b`
run returned HTTP 500 in 43 s while `gateway-health.sh` was all-green; the
broker's `/api/tags` listing showed no qwen2.5 variants). Reproduce today:

```bash
ssh desktop-agent 'curl -s -m 20 http://127.0.0.1:11436/api/tags'   # what Ollama actually serves
grep -n 'model: ollama/' /Users/prestonbernstein/dev/llm-gateway/config/config.yaml  # what the catalog claims
```

**Fix.** **None yet — OPEN.** Options: pull the missing models on the Ollama
instance, or re-point/remove the dead entries. Either way it is a config or
backend change through `llm-gateway-change-control` — do not silently edit
the live config.

**Current status (2026-07-02).** **OPEN.** Smoke-test guidance across the
skill library uses `ollama/batch/qwen3-vl:30b` (the only serveable entry)
until this closes. Operational KNOWN DEFECT note and the re-check one-liner:
`llm-gateway-diagnostics-and-tooling`; smoke/checklist impact:
`llm-gateway-validation-and-qa`.

---

## How to append to this chronicle

New investigation, failure, or dead end? Add it here (and ONLY here — sibling
skills get a one-line citation at most). Copy this template as
`## Incident N — <short name> (<date>) — <fixed | open | constraint>`:

```markdown
## Incident N — <short name> (<YYYY-MM-DD>) — <fixed | fixed-with-scars | open | open constraint>

**Symptom.** What was observed, verbatim where possible (exact error text, HTTP
status, journal line). Who/what noticed it.

**Root cause.** The actual mechanism, not the first guess. If diagnosed but
unfixed, say "diagnosed, not yet fixed".

**Fix.** What was changed, where (commit hash if in repo; exact live path if
not), and by whom. "None yet" is a valid entry.

**Evidence.** Copy-pasteable read-only commands that reproduce the observation
today: `git show <hash>`, `grep -n <pattern> <file>`, and for live-box facts
the exact `ssh desktop-agent 'sudo <read-only command>'`. If the evidence is
historical and not reproducible, say so explicitly and name who verified it and
when. NEVER paste credential values or litellm.env contents.

**Current status (<date>).** Fixed / open / constraint, plus every remaining
scar or landmine the fix left behind (stale docs, example files, unversioned
live files). Cross-reference the sibling skill that owns the remediation or
rule, by exact name.
```

Rules when appending: date-stamp everything; keep the incident numbering
monotonic; if a fix creates a new rule, the rule goes to
`llm-gateway-change-control` and gets cited here; if a fix is a remediation
step, it goes to `llm-gateway-timeout-and-drift-campaign`. Update an existing
incident's **Current status** (with a new date stamp) rather than opening a
duplicate when a known incident recurs or closes.

## When NOT to use this skill

- **Live triage of a symptom happening right now** — start with
  `llm-gateway-debugging-playbook` (symptom → check tree); come here once you
  suspect a recurrence or need history.
- **Executing fixes for the open items** (timeout stack, drift reconciliation,
  shim version control) — `llm-gateway-timeout-and-drift-campaign` owns the
  remediation plan and decision menus.
- **The rules these incidents produced** (what needs sign-off, what never to
  hand-edit) — `llm-gateway-change-control`.
- **What the config flags/timeouts mean** — `llm-gateway-config-and-flags`
  (owns the canonical timeout-layer table).
- **Model/tier catalog and routing semantics** — `litellm-routing-reference`.
- **Installing, updating, restarting the service** —
  `llm-gateway-install-and-operate` (but read Incident 7 before ever running
  update.sh).

## Provenance and maintenance

Written 2026-07-02 from: the full git history of
`/Users/prestonbernstein/dev/llm-gateway` (4 commits, single branch `main`),
direct reads of every repo file, and read-only SSH to the live host
(`ssh desktop-agent`). Incidents 4 and 5's runtime observations (429s,
60–120 s latencies, account rate-limiting) are historical — verified 2026-07-02
by the retiring principal during the LightRAG saga and not re-reproducible
without re-running bulk workloads.

One-line re-verification of everything volatile:

```bash
git -C /Users/prestonbernstein/dev/llm-gateway log --oneline                          # still 4 commits ending 42ca4bc?
grep -n database_url /Users/prestonbernstein/dev/llm-gateway/config/config.example.yaml  # Incident 1 landmine still present?
grep -rn "litellm.db" /Users/prestonbernstein/dev/llm-gateway/README.md               # Incident 1 stale README section still present?
grep -n request_timeout /Users/prestonbernstein/dev/llm-gateway/config/config.yaml    # repo still 120?
ssh desktop-agent 'sudo ls -la /etc/litellm/ /var/lib/litellm/'                       # perms, .bak files, absence of litellm.db
ssh desktop-agent 'sudo grep -n "4002\|request_timeout\|claude-fable-5" /etc/litellm/config.yaml'  # drift still live?
ssh desktop-agent 'sudo grep -n "input=prompt\|stdin=subprocess.PIPE\|timeout" /opt/claude-cli-server/server.py'  # shim fix + timeout defaults intact?
ssh desktop-agent 'sudo journalctl -u litellm --since "-24h" --no-pager | grep -ci APITimeoutError'  # Incident 6 still firing?
ssh desktop-agent 'curl -s -m 20 http://127.0.0.1:11436/api/tags'                      # Incident 8: qwen2.5 models still not pulled?
```

If any of these disagree with an incident's "Current status", update the
incident (new date stamp) — do not silently trust this file over the live
system.
