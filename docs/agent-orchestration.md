# Agent orchestration

The query agent lives in `app-service`'s Route Handlers (Next.js on AWS App Runner, VPC App) — the same deployment that serves the analyst-facing UI — and is the only component analysts talk to. It exists to solve one problem stated directly in the RFP: *"break complex queries into multi-step searches"* and return **only** verifiable, schema-conformant answers.

**Scope note:** the RFP's example query asks the agent to also *"summarize what was displayed on-screen"* — that requires a visual-frame sampling stage, which isn't implemented yet (see the scope note in [architecture.md](architecture.md)). Everything below describes the transcript-only agent that exists today; the tool catalog is written so a visual retrieval tool can be added later without changing the orchestration loop or the grounding controls.

**Implementation status:** `app-service`'s `/api/query` route today runs a single retrieval-then-synthesize pass — `search_transcripts` once, then one Bedrock call to decide relevance and phrase claims — not the full bounded, multi-step tool-calling loop described below. `get_video_metadata` and `get_transcript_window` aren't wired in as callable tools yet, so there's no cross-referencing sub-step for a plan like the crypto-assets example. The grounding controls that don't depend on multi-step planning are enforced regardless: synthesis never runs on an empty evidence log, and `video_id`/`timestamp_s` always come from the vector search hit itself, never from the model's own output, so a hallucinated citation can't reach the response.

## Why an agent instead of a single retrieval call

A question like *"Identify all instances where an advisor discussed unapproved crypto assets in Q2, return the precise video timestamps"* is really three operations chained together:

1. Filter the video corpus to Q2.
2. Semantically search transcripts for crypto-asset discussion, and cross-reference against a list of approved assets.
3. Assemble everything into a single schema-valid, cited answer.

A single vector search cannot do step 2's filtering-plus-negation ("unapproved") on its own. The agent decomposes the question into a plan, executes each step with a specific tool, and only then synthesizes.

## Orchestration loop

The agent runs a bounded tool-calling loop against a Bedrock foundation model:

```
plan(question) -> [sub-task, sub-task, ...]
for sub_task in plan:
    tool_call = model.decide_next_action(sub_task, evidence_so_far)
    result = execute(tool_call)          # see Tool catalog below
    evidence_so_far.append(result)
answer = model.synthesize(question, evidence_so_far)   # schema-constrained
validate(answer)  # reject and retry synthesis if invalid, see schemas.md
```

The loop has a hard step budget and a wall-clock timeout per request; if the budget is exhausted before an answer is reached, the API returns a typed "insufficient evidence" response rather than looping indefinitely or guessing.

## Tool catalog

| Tool | Backing service | Purpose |
|---|---|---|
| `search_transcripts(query, filters)` | Amazon S3 Vectors | Vector similarity search over transcript-segment embeddings, with a metadata filter on date range, video ID, or speaker/advisor if tagged |
| `get_video_metadata(video_id)` | Amazon RDS | Resolves a video ID to recording date, source system, participants, and ingestion status |
| `get_transcript_window(video_id, timestamp, window_s)` | Amazon RDS | Pulls surrounding transcript text for context around a hit, so the model isn't reasoning from a single embedding match in isolation |

Not yet implemented: a `search_visual_observations`/`describe_frame`-style tool over sampled video frames — see the scope note above.

Every tool call and its result is appended to an append-only evidence log for the request. The synthesis step is instructed — and structurally constrained via the schema in [schemas.md](schemas.md) — to cite only entries present in that log.

## Grounding and anti-hallucination controls

Because this system operates in a regulated environment, "the model sounded confident" is not an acceptable bar. Controls:

- **Retrieval-before-synthesis, always.** The model is never asked an open question without first executing at least one retrieval tool call; there is no code path that lets synthesis run against an empty evidence log.
- **Citation-required schema.** The response schema (see [schemas.md](schemas.md)) requires a `video_id` and `timestamp_s` for every claim. A claim with no matching entry in the evidence log fails validation and forces a retry.
- **Confidence scoring.** Each finding carries a `confidence` score derived from the retrieval similarity score. Low-confidence findings are surfaced, not suppressed — the analyst decides materiality, the system doesn't hide uncertainty.
- **Negative-result honesty.** If no evidence clears the relevance threshold, the agent returns an explicit "no matching instances found" result rather than a low-confidence guess — an empty `findings` array is a valid, schema-conformant answer.
- **Bounded loop.** The step budget above prevents runaway tool-calling and caps worst-case cost and latency per query.

## Where this runs and why App Runner

The agent's tool-calling loop is stateful across several round-trips (plan → multiple retrievals → synthesize → validate → possible retry) and benefits from a warm runtime rather than paying Lambda cold-start latency on every step of a multi-second-to-multi-minute session. AWS App Runner gives that always-warm, autoscaled container runtime without managing the underlying compute — consistent with keeping the ingestion side (bursty, embarrassingly parallel) on Lambda while the query side (session-shaped, latency-sensitive) runs on App Runner.
