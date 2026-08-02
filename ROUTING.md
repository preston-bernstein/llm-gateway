# Model routing — the right model for the job (FrugalGPT)

FrugalGPT is a cost-saving routing strategy from a research paper: try a cheap model first, and escalate to a pricier one only if the cheap one's answer fails a quality check. This repo's gateway serves a catalog of models; **services own the cascade policy** — which tier to try first, and when to escalate. The shared tier contract every service should follow:

| Tier | Gateway model_name | Use |
|---|---|---|
| **LOCAL** | `ollama/interactive/qwen2.5`, `ollama/batch/*` | Free, private, runs on our own hardware. For bulk or simple work: classification, extraction, embeddings. |
| **FAST** | `gemini-2.5-flash` | Cheap, fast cloud model — the first cloud tier to try after LOCAL. |
| **MID** | `claude-sonnet-4-6`, `runpod/qwen2.5-72b` | Strong reasoning at moderate cost. |
| **FRONTIER** | `claude-opus-4-8`, `gemini-2.5-pro` | Highest accuracy — for hard reasoning or judgment calls. |

## FrugalGPT principle: accuracy first, cost second

- **Bulk or simple work**: start at LOCAL, and escalate only if the cheap model fails a quality gate (for example, it returns invalid JSON). Most calls never leave the free tier.
- **Accuracy-critical work**: skip the cascade and go straight to FRONTIER. Don't risk an error to save a fraction of a cent where correctness matters.
- **Middling work**: cascade from MID to FRONTIER.

The quality gate that decides whether a cheap model's answer is good enough is a verifier — for example, checking that JSON output is valid and has the right shape, or running a self-consistency check. A cheap model's answer only counts as a "win" if it passes the gate; otherwise the request escalates to the next tier.

The gateway exports every call (tier, tokens, latency, cost) as Prometheus metrics — see the Observability section of README.md for the exact metric names, including `litellm_deployment_successful_fallbacks`. That metric is what makes it visible when a cascade lands on a *different* model than it asked for: a silent quality downgrade, not just a cost line, that would otherwise hide behind a normal HTTP 200 response.

## Reference implementation

`algo-factory` (a sibling repo) implements this pattern in its `ModelRouter` (`src/algo_factory/agents/router.py`): each task gets a `RoutePolicy` (mode `cascade` or `best`, plus a tier chain), escalation is gated on JSON validity, and every call goes through this gateway. Other services should reuse the same tier names so routing policy stays consistent across the whole stack.

## RunPod

RunPod is a serverless GPU hosting service. The `runpod/*` entries point at a RunPod-hosted vLLM endpoint — a middle option, in cost and capability, between the local broker and the cloud frontier APIs, for running large open-weight models on demand. To use it, set the endpoint ID in `config.yaml` and `RUNPOD_API_KEY` in the env file.
