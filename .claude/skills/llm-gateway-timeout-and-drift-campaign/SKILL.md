---
name: llm-gateway-timeout-and-drift-campaign
description: >
  Executable campaign plan for the gateway's hardest live problem: claude-* calls dying with
  litellm.exceptions.Timeout (APITimeoutError, timeout value=300.0) on the claude-cli-server
  (:4002) backend, coupled with the live /etc/litellm/config.yaml being a hand-edited overlay
  AHEAD of the public repo that scripts/update.sh unconditionally clobbers. Load this skill when:
  claude-* calls time out or hang through the gateway (port 4000); APITimeoutError appears in
  `journalctl -u litellm`; you are planning to run scripts/update.sh for ANY reason; you are asked
  to reconcile the repo config vs the live config; or you are asked to "fix the timeout" on the
  Claude routing path. Phased, decision-gated, success measured by numbers. Do NOT load for
  general debugging (llm-gateway-debugging-playbook) or routine install/update mechanics
  (llm-gateway-install-and-operate).
---

# Timeout + Drift Campaign — claude-* via claude-cli-server (:4002)

**Status: OPEN campaign as of 2026-07-02.** Root cause of the timeout stack mismatch is not
fixed; the live `request_timeout` was already raised 120→300 as a mitigation and calls STILL
die at 300 s. ASSUMPTION (coordinator-endorsed, 2026-07-02): the live :4002 routing is a
LOCAL OVERLAY and the drift-reconciliation decision is reserved for Preston.

This skill is a runbook for a future maintainer session (ASSUMPTION, coordinator-endorsed,
2026-07-02: audience = Sonnet-class Claude Code on the Mac, `ssh desktop-agent`, NOPASSWD
sudo, permitted to restart/modify the service under change-control discipline). Every phase
states exact commands, the numbers you should
see, and what to do when you see something else. **Do not skip Phase 0.** Do not perform any
mutation without the gates in llm-gateway-change-control.

## The problem in two coupled halves

**(A) Timeout stack mismatch (Incident 6, OPEN).** `journalctl -u litellm` on 2026-07-02 shows
repeated:

```
litellm.exceptions.Timeout: litellm.Timeout: APITimeoutError - Request timed out.
Error_str: Request timed out. - timeout value=300.0, time taken=300.0 seconds
```

Several timeout layers exist on the claude-* path and are NOT aligned. In brief
(values 2026-07-02; the canonical layer table, including client-side layer 0, lives in
llm-gateway-config-and-flags): LiteLLM `request_timeout` (live **300** / repo **120**) →
shim per-request `timeout` body param (default **180**, enforced as the subprocess timeout)
→ the shim's streaming path, which has **NO timeout at all**.

The backend (`claude-cli-server` on 127.0.0.1:4002, wrapping `claude -p`) has a floor latency
of **60–120 s for trivial prompts** and self-rate-limits Preston's Claude subscription — which
is SHARED with his live Claude Code sessions — under volume (Incident 5). So requests that a
normal API would answer in seconds routinely take minutes here, and long jobs exceed every layer.

**(B) Config drift + clobber trap.** Live `/etc/litellm/config.yaml` is a hand-edited overlay
AHEAD of the public repo. Three deltas, in one line (verified 2026-07-02; the enumerated
delta list's one home is llm-gateway-config-and-flags, drift section): claude-* →
`openai/<model>` at `api_base: http://localhost:4002/v1` + `api_key: "none"` (repo routes to
a credit-less `anthropic/` API account); live-only `claude-fable-5` (the shim silently serves
it as sonnet); live `request_timeout: 300` vs repo `120`.

`scripts/update.sh` line 16 does `cp "$REPO_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"`
**unconditionally**, then restarts the service. Running it today silently reverts Claude traffic
to no-credit API billing (all claude-* calls fail with auth/credit errors) and drops
claude-fable-5. ASSUMPTION (coordinator-endorsed, 2026-07-02): the overlay is local policy,
and whether it becomes canonical in the (public) repo is an **OPEN decision reserved for
Preston** — this campaign guards the clobber and prepares the options; it does not decide.

The two halves are coupled: any timeout fix in config.yaml is itself new drift until the
reconciliation decision lands, and it dies the next time someone runs update.sh unguarded.

---

## Phase 0 — Baseline snapshot (read-only except 0.5, which is ONE subscription-consuming call)

Run all of these before touching anything. Record every number in your working notes; the exit
criteria at the bottom compare against them.

**0.1 Service alive**

```bash
ssh desktop-agent "systemctl is-active litellm"
```

Expected: `active`.
**GATE:** anything else (`inactive`, `failed`, `activating` loop) → this is not the timeout
campaign, it is an outage. Stop; go to llm-gateway-debugging-playbook.

**0.2 Liveliness**

```bash
ssh desktop-agent "curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health/liveliness"
```

Expected: `200` (no auth needed for liveliness).
**GATE:** non-200 → stop, go to llm-gateway-debugging-playbook before resuming here.

**0.3 Drift diff (the central check).** `-` lines = LIVE-only, `+` lines = REPO-only (same
orientation as `config-drift.sh` in llm-gateway-diagnostics-and-tooling):

```bash
ssh desktop-agent "sudo cat /etc/litellm/config.yaml" \
  | diff -u - /Users/prestonbernstein/dev/llm-gateway/config/config.yaml
```

Expected: **non-empty**, showing exactly the three known deltas listed above (claude-* →
`openai/` + `api_base: http://localhost:4002/v1` + `api_key: "none"`; added `claude-fable-5`
block; `request_timeout: 120` → `300`) plus overlay comment lines. Verified 2026-07-02.

**GATE — branch on what you see:**
- **Diff EMPTY** → someone already ran update.sh. Claude routing has reverted to `anthropic/`
  with a no-credit API key: claude-* calls now fail *differently* (auth/credit errors, not
  timeouts). Restore the overlay FIRST, then resume this campaign:
  1. List backups: `ssh desktop-agent "sudo ls -la /etc/litellm/"`. As of 2026-07-02 there are
     two: `config.yaml.bak.1782940343` and a file literally named `config.yaml.bak.$(date +%s)`
     (a past operator quoted the command substitution — see Phase 2).
  2. Find the newest backup that actually contains the overlay — the glob must expand inside
     a ROOT shell (a plain `sudo grep` gets the glob expanded by the non-root agent shell,
     which cannot read `/etc/litellm`, so grep receives the literal glob and fails rc=2):
     `ssh desktop-agent 'sudo bash -c "grep -l localhost:4002 /etc/litellm/config.yaml.bak.*"'` —
     and do NOT trust filename recency alone; the literal-`$(date +%s)` file breaks lexical sorting.
  3. Restore that file over `/etc/litellm/config.yaml` (preserving `root:litellm` / `640` perms)
     and restart — as a change-controlled mutation per llm-gateway-change-control, with the
     validation checklist from llm-gateway-validation-and-qa.
- **Diff shows the three known deltas + nothing else** → nominal; proceed.
- **Diff shows EXTRA unknown deltas** → someone hand-edited further. Record them; treat each as
  a fourth/fifth drift item in Phase 2; do not "clean them up" reflexively.

**0.4 Timeout error count (your "before" number)**

```bash
ssh desktop-agent "sudo journalctl -u litellm --since '-48 hours' | grep -c APITimeoutError"
```

Record N. On 2026-07-02 this returned **117** — note `grep -c` counts *lines*, and each timeout
event emits ~5 matching lines in a burst, so 117 lines ≈ **24 events** (verified: 23 bursts × 5
+ 1 × 2 = 117 in the 48 h window). Expected while the problem is live: N > 0, often clustered
in bursts (observed cluster 2026-07-02 ~08:01–09:22).
**GATE:** N = 0 over 48 h → the symptom is not currently reproducing. Do NOT invent work: either
traffic stopped (check with the callers) or someone already mitigated. Investigate which before
proceeding to Phase 3.

**0.5 Backend floor latency — ONE timed trivial call, direct to :4002**

```bash
ssh desktop-agent "curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 240 \
  -X POST http://127.0.0.1:4002/v1/chat/completions \
  -H 'Content-Type: application/json' \
  --data '{\"model\":\"claude-haiku-4-5\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}]}'"
```

Expected: `200` in **60–120 s** (yes, for a one-word prompt — that is the documented floor,
Incident 5). This call costs a hit on the shared subscription; one is enough for Phase 0.
**GATE:** non-200 or > 240 s on a trivial prompt → the backend itself is degraded; you are in
class T2 (Phase 1) — check claude-cli-server before blaming the gateway.

**0.6 Sanity on the adjacent service**

```bash
ssh desktop-agent "systemctl is-active claude-cli-server; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4002/v1/models"
```

Expected: `active` and `200` (verified 2026-07-02).

---

## Phase 1 — Characterize the timeout (read-only, cheap)

Goal: decide which mismatch class you are in before proposing any fix. Do NOT load-test.

**1.1 Which caller/workload hits 300 s?**

```bash
ssh desktop-agent "sudo journalctl -u litellm --since '-48 hours' | grep -B2 -A8 'APITimeoutError' | head -80"
```

Look at timestamps and any request context near the errors: are failures clustered around a
known bulk job (e.g. a LightRAG-style extraction run), or scattered across interactive use?
Cross-check the shim side:

```bash
ssh desktop-agent "sudo journalctl -u claude-cli-server --since '-48 hours' | tail -100"
```

**1.2 Streaming or not? (the discriminating check for S1/S3)**

Reason it through before measuring: the shim's *non-streaming* handler has a 180 s subprocess
timeout. If a non-streaming call exceeds 180 s, the shim should kill the subprocess and return
an error at ~180 s — LiteLLM would then log a backend/API error, **not** sit until its own
300 s. Deaths at exactly `time taken=300.0` therefore imply the shim never answered, which means
either (a) the request took the **streaming** path (Popen, no timeout at all), or (b) the caller
sent a `timeout` body param > 300, overriding the 180 default. Discriminate:

- `ssh desktop-agent "sudo journalctl -u claude-cli-server --since '-48 hours' | grep -ci 'TimeoutExpired'"` —
  nonzero means the 180 s non-streaming timeout IS firing for some calls (those produce shim 5xx,
  not LiteLLM 300 s deaths).
- Check whether the failing callers set `stream: true` (ask the caller / read its config; the
  LightRAG-era clients did non-streaming, but do not assume).

Record the answer — Phase 3 S1 vs S3 depends on it.

**1.3 Backend latency distribution — 2–3 spaced trivial calls, NOT a load test**

Repeat the Phase 0.5 curl **at most 2–3 times, spaced minutes apart** (shared subscription —
Incident 5 is the reason this rule exists). Record each `time_total`.

**GATE — classify:**

| Observation | Class | Meaning | Next |
|---|---|---|---|
| Trivial calls succeed in 60–120 s; only long/bulk prompts hit 300 s | **T1 — mismatch class** | Backend is at its normal (slow) baseline; long jobs exceed every timeout layer | Phase 2, then Phase 3 |
| Even trivial calls fail or exceed ~240 s | **T2 — degraded backend** | claude-cli-server or the CLI itself is sick (auth expired, rate-limit lockout, hung process) | Check `journalctl -u claude-cli-server`, CLI auth state (`claude` login status under `/home/preston`); fix the backend first — Phase 3 is pointless against a dead backend |

The 2026-07-02 evidence (trivial 60–120 s floor + failures on sustained/long work) points to
**T1**, but re-verify — T2 has happened during the LightRAG saga.

---

## Phase 2 — Drift containment (MUST precede any config edit)

Nothing in Phase 3 may touch `/etc/litellm/config.yaml` or the repo until this phase is done.
Any config edit you make is itself new drift; contain first.

**2.1 The guarded-update ritual** (full mechanics: llm-gateway-install-and-operate; repeated
here because it is safety-critical):

1. **Diff before anything** — Phase 0.3 command. Never run `scripts/update.sh` while that diff
   is non-empty and unreconciled.
2. **Backup — quoting trap, full explanation in llm-gateway-install-and-operate §3 step 2:**

   ```bash
   ssh desktop-agent 'sudo cp /etc/litellm/config.yaml "/etc/litellm/config.yaml.bak.$(date +%s)"'
   ```

   Verify your backup got a real epoch suffix (not a literal `$(date +%s)`):
   `ssh desktop-agent "sudo ls -la /etc/litellm/"`.
3. **Reconcile consciously** — apply intended changes by editing the live file (or a merged
   copy) deliberately, never by blind `cp` from the repo. Restart + validate per
   llm-gateway-change-control and llm-gateway-validation-and-qa.

This backup step (2.1 step 2) is a mutation; it is low-risk but still goes in your change log.

**2.2 Reconciliation menu — OPEN DECISION, reserved for Preston. Present, do not decide.**

| Option | What it is | Cost | Theory obligations (what must be true for it to be correct) |
|---|---|---|---|
| **A — Keep overlay local** (status quo) | Live config stays a documented local overlay; repo untouched; every update.sh run is preceded by a hand diff/merge | Cheapest; zero code/repo change | (1) Every future operator actually reads this skill / the drift warning before update.sh — the guard is procedural, not mechanical. (2) The overlay stays small enough to hand-merge. (3) The drift stays documented and the Phase 0.3 diff stays the source of truth. |
| **B — Canonicalize overlay into repo** | Commit the :4002 routing, claude-fable-5, and timeout value to `config/config.yaml`; update.sh becomes safe again | One commit + doc updates | (1) **Preston accepts public-repo exposure** of the :4002 subscription-wrapper pattern (`claude -p --dangerously-skip-permissions` wrapping, `api_key: "none"`) — the repo is public. (2) Preston accepts that the repo would then advertise `claude-fable-5`, which the shim **silently serves as sonnet** (fable is not a CLI alias). (3) The :4002 routing is intended to be durable, not a temporary out-of-credits workaround. |
| **C — Repo gains an overlay mechanism** | update.sh learns to refuse (or three-way merge) when live differs from the repo copy — e.g. keep a `config.yaml.deployed` snapshot and abort on unexpected live changes. Variants of C include a **private (git-ignored) overlay file** that update.sh re-applies after the copy — same decision class, same obligations | A repo code change, through change-control | (1) The refuse/merge logic is actually correct for YAML (safest form: refuse + print diff, human merges). (2) It fails CLOSED (refuses) on any doubt. (3) It is tested against the current live drift before being trusted. |

Preston decides A/B/C (or a combination — C guards the script regardless of A vs B). Until he
does: behave as Option A, and treat the update.sh clobber warning as active.

---

## Phase 3 — Timeout alignment: ranked solution menu

Each option: mechanism → theory obligation → exact edit → predicted post-fix numbers →
validation. Every one goes through the promotion protocol at the end of this phase. Do not
combine unrelated edits in one change.

### S4 — Route long/bulk work LOCAL by policy (recommended first, no code change)

- **Mechanism:** the tier doctrine (litellm-routing-reference): services own the cascade;
  :4002 is LOW-VOLUME only. Move any bulk/long workload currently aimed at claude-* to the
  local Ollama models via the broker lanes already in config.yaml
  (`ollama/batch/*` → :11436). This shrinks the population of requests that can ever reach
  300 s. Precedent: Incident 5 — LightRAG extraction moved local and the problem stopped for
  that workload.
- **Theory obligation:** the failing traffic identified in Phase 1.1 is actually redirectable
  (quality requirements permit a local model). If the failing calls are genuinely
  frontier-quality-required, S4 reduces exposure but cannot eliminate it.
- **Exact edit:** none in this repo — caller-side config change in the offending service.
- **Predicted numbers:** APITimeoutError line count (Phase 0.4 command) drops toward 0 for the
  redirected workload's time windows; :4002 sees only short calls.
- **Validation:** re-run Phase 0.4 after 48 h of the caller's normal traffic.

### S1 — Align layers so the SHIM fires first with a clean error (recommended with S4)

- **Mechanism:** make every shim-side timeout strictly less than LiteLLM's `request_timeout`,
  so a slow call dies at the shim with a real 5xx + message ("claude CLI exceeded N s") instead
  of an opaque LiteLLM 300 s transport timeout. Today 180 < 300 holds for the *non-streaming
  default* — yet calls die at 300, which is exactly why Phase 1.2 is mandatory: the observed
  deaths imply the streaming path (no timeout) or an oversized caller-supplied `timeout` body
  param. S1 means closing whichever gap Phase 1.2 found: cap the caller's `timeout` body param
  below `request_timeout`, and/or pair with S3 if streaming is implicated.
- **Theory obligation:** Phase 1.2 correctly identified which path the dying requests take. If
  you cannot demonstrate it from logs, S1 is a guess — do the discriminating check first.
- **Exact edit:** depends on Phase 1.2 outcome — caller-side (`timeout` body param ≤ 240) and/or
  S3. Optionally also settle `request_timeout` at a deliberate value (e.g. keep 300) so the
  ordering shim(≤240) < LiteLLM(300) is explicit and documented.
- **Predicted numbers:** zero `time taken=300.0` lines in `journalctl -u litellm`; slow calls
  now surface as shim-originated errors at ≤ 240 s with a readable message.
- **Validation:** provoke ONE deliberately long prompt (a single call, not a load test) and
  confirm it dies at the shim's limit, not LiteLLM's.

### S2 — Per-model `timeout` in litellm_params (CANDIDATE — verify before use)

- **Mechanism:** LiteLLM supports a per-model `timeout` key inside `litellm_params`, which
  would let claude-* carry a generous timeout without raising the global `request_timeout`
  for Gemini/Ollama (which never need 300 s). **Candidate mechanism — verify against LiteLLM
  1.90.1 documentation before use** (that is the pinned live version, verified 2026-07-02).
- **Theory obligation:** confirmed present and honored in 1.90.1 for `openai/`-provider routes;
  confirmed interaction with global `request_timeout` (which wins when both are set).
- **Exact edit:** add `timeout: <value>` under each claude-* `litellm_params` block in the LIVE
  `/etc/litellm/config.yaml` (this widens drift — Phase 2 ritual applies; note it in the drift
  record), and optionally lower global `request_timeout` back toward the repo's 120 for
  everything else.
- **Predicted numbers:** non-claude models fail fast (≤ 120 s) again; claude-* keeps its
  deliberate ceiling; timeout errors carry the per-model value in the message.
- **Validation:** one Gemini call and one claude call through the gateway; confirm each honors
  its own ceiling (read the timeout value in any error message / logs).

### S3 — Add a timeout to the shim's streaming path (most invasive)

- **Mechanism:** edit `/opt/claude-cli-server/server.py` so the streaming branch (`Popen`) gets
  a wall-clock kill (e.g. watchdog that terminates the child and closes the stream with an error
  event after N s). Removes the "no timeout at all" layer.
- **Theory obligation:** Phase 1.2 showed streaming requests are among the 300 s deaths. Also:
  the kill must clean up the child `claude` process (no orphans holding the subscription).
- **Extra care — this file is OUTSIDE this repo, UNVERSIONED, and the service runs as `preston`
  (a known house-rule violation, tracked separately — do not silently "fix" the service user in
  the same change).** The shim has **no git history**: back it up first —
  `ssh desktop-agent 'sudo cp /opt/claude-cli-server/server.py "/opt/claude-cli-server/server.py.bak.$(date +%s)"'`
  (same quoting trap as Phase 2). Full change-control discipline; restarting
  `claude-cli-server` interrupts any in-flight claude call.
- **Exact edit:** designed at execution time against the current 186-line file — read it first;
  do not paste code from this skill.
- **Predicted numbers:** streaming calls that would previously hang die at the shim's chosen
  limit (< `request_timeout`); zero LiteLLM-side 300 s deaths attributable to streaming.
- **Validation:** one streaming call with a deliberately long prompt; confirm shim-side
  termination and no orphaned `claude` processes (`pgrep -f 'claude -p'` empty afterwards).

### Ranking and promotion protocol

**Rank: S4 + S1 first** (cheapest, safest, attack demand and error clarity together) →
**S2 candidate** (only after doc verification) → **S3 most invasive** (only if Phase 1.2 proves
streaming is implicated).

**Promotion protocol — every fix, no exceptions:**
1. Proposed as a change through llm-gateway-change-control gates (backup, single change,
   restart window, rollback plan).
2. Validated against the llm-gateway-validation-and-qa checklist (liveliness, model list,
   one smoke call per affected route).
3. Carries a **measurable exit criterion** declared BEFORE the change (e.g. "Phase 0.4 count
   = 0 over the next 7 days"), and is reverted if the number is not met.

---

## Exit criteria (numbers, not vibes)

The campaign is DONE when all of these hold:

1. **0** `APITimeoutError` lines from
   `ssh desktop-agent "sudo journalctl -u litellm --since '-7 days' | grep -c APITimeoutError"`
   over 7 days of *normal traffic* (confirm traffic actually flowed — zero errors on zero
   requests proves nothing; baseline was 117 lines/48 h on 2026-07-02).
2. Phase 0.3 drift diff returns a **KNOWN, documented delta** — exactly the deltas recorded in
   this skill / the drift record, or empty post-reconciliation once Preston has decided A/B/C.
   No surprise deltas.
3. Trivial claude smoke via the **gateway** completes with HTTP 200 in **< 180 s**:

   ```bash
   ssh desktop-agent 'sudo bash -c "source /etc/litellm/litellm.env; curl -s -o /dev/null -w \"%{http_code} %{time_total}s\n\" --max-time 240 http://127.0.0.1:4000/v1/chat/completions -H \"Authorization: Bearer \$LITELLM_MASTER_KEY\" -H \"Content-Type: application/json\" -d \"{\\\"model\\\":\\\"claude-haiku-4-5\\\",\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"Reply with the single word OK.\\\"}]}\""'
   ```

   (The key is sourced on the remote host and never printed — never echo `$LITELLM_MASTER_KEY`
   or copy litellm.env contents anywhere.)
4. Slow/long calls fail **fast and legibly** at the shim layer (S1/S3 validation), not at 300 s
   in the transport.

## Fenced-off wrong paths (do NOT)

- **Do NOT run `scripts/update.sh` blindly.** Line 16 clobbers the live overlay unconditionally;
  claude-* routing reverts to a no-credit API key and claude-fable-5 vanishes. Phase 2 ritual
  first, every time.
- **Do NOT re-add `database_url` to "restore spend tracking"** without installing and migrating
  the prisma client first — that exact line broke startup once (Incident 1; details in
  llm-gateway-failure-archaeology). `config/config.example.yaml` still carries the bad line;
  never copy it verbatim.
- **Do NOT load-test :4002.** It fronts Preston's shared Claude subscription; sustained volume
  self-rate-limits the account and degrades his live sessions (Incident 5). Phase 1 allows 2–3
  spaced trivial calls, total.
- **Do NOT point anything at raw Ollama :11434.** House rule. Broker lanes only (127.0.0.1:11435
  interactive / :11436 batch from the gateway box).
- **Do NOT "fix" the claude-fable-5 → sonnet aliasing silently** as part of this campaign. It is
  a real inconsistency, but it is a separate change with its own change-control ticket; bundling
  it here muddies validation.
- **Do NOT just keep raising `request_timeout`.** 120→300 was already tried and calls still die
  at exactly the new ceiling — the ceiling is not the disease. Raising it again only makes hangs
  longer and hides the layer mismatch (treating the symptom).
- **Do NOT change the claude-cli-server service user (`preston` → service user) inside this
  campaign.** Known open item, separate change.

## When NOT to use this skill

- Gateway is down / liveliness non-200 / service flapping → **llm-gateway-debugging-playbook**.
- You want the incident back-stories (database_url, argv-prompt 502, quota wall, bulk
  abandonment) → **llm-gateway-failure-archaeology**.
- You need the full timeout-layer/flag reference table → **llm-gateway-config-and-flags**.
- Routine install/update/restart mechanics and the guarded-update procedure in full →
  **llm-gateway-install-and-operate**.
- Choosing which model/tier a workload should use → **litellm-routing-reference**.
- Ready-made diagnostic scripts/one-liners → **llm-gateway-diagnostics-and-tooling**.
- Evidence standards for declaring anything "fixed" → **llm-gateway-validation-and-qa**.
- Architectural invariants (what the gateway owns vs what services own) →
  **llm-gateway-architecture-contract**.

## Provenance and maintenance

Grounded 2026-07-02 by direct repo reads + read-only SSH (`ssh desktop-agent`). Volatile facts
and their one-line re-verification commands:

- Service active + liveliness 200:
  `ssh desktop-agent "systemctl is-active litellm; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health/liveliness"`
- Drift deltas (three known, 2026-07-02; `-` = live-only, `+` = repo-only):
  `ssh desktop-agent "sudo cat /etc/litellm/config.yaml" | diff -u - /Users/prestonbernstein/dev/llm-gateway/config/config.yaml`
- Timeout baseline (117 lines ≈ 24 events / 48 h on 2026-07-02):
  `ssh desktop-agent "sudo journalctl -u litellm --since '-48 hours' | grep -c APITimeoutError"`
- Backup inventory incl. the literal `$(date +%s)` artifact:
  `ssh desktop-agent "sudo ls -la /etc/litellm/"`
- update.sh still clobbers unconditionally (re-check after any repo change):
  `grep -n 'cp .*config.yaml' /Users/prestonbernstein/dev/llm-gateway/scripts/update.sh` → line 16, no guard.
- Live `request_timeout` value:
  `ssh desktop-agent "sudo grep request_timeout /etc/litellm/config.yaml"` → `request_timeout: 300`.
- LiteLLM version pin for S2 doc-verification: 1.90.1 (verified 2026-07-02);
  `ssh desktop-agent "/opt/litellm/venv/bin/litellm --version"`.
- Shim facts (180 default / streaming no-timeout / 186 lines) — re-read before S1/S3:
  `ssh desktop-agent "sudo wc -l /opt/claude-cli-server/server.py"`.

OPEN items as of 2026-07-02: reconciliation decision A/B/C (Preston); Incident 6 root cause;
claude-fable-5→sonnet aliasing; claude-cli-server service user. Update this skill's date-stamped
numbers after any phase executes or any decision lands.
