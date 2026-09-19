# Evaluation strategy

"Trust me, it's accurate" is not acceptable for a system that flags regulatory violations. This document describes how Sightline's accuracy is measured, not asserted.

## 1. Golden dataset

A held-out set of videos is hand-annotated by compliance SMEs (not by the team building the system) with:

- Every instance of a target category of statement (e.g., unapproved-asset discussion), with exact start/end timestamps.
- The correct on-screen description at each flagged timestamp.
- A set of explicit **negative** cases — videos or segments that contain superficially similar but non-violating language — to test for false positives, which are as costly as false negatives in a compliance context (they burn analyst time re-reviewing the agent's output).

The golden set is versioned and grows over time as new query patterns and edge cases are identified in production.

## 2. Metrics

| Metric | What it measures | Target |
|---|---|---|
| Segment-level recall | Of all true instances in the golden set, what fraction did the agent surface as a `finding`? | High recall is the priority metric — a missed violation is the failure mode this system exists to eliminate. |
| Segment-level precision | Of the `findings` returned, what fraction correspond to a real, annotated instance? | Tracked to bound analyst review burden; a target ceiling on false-positive rate is set jointly with the compliance team, not fixed unilaterally. |
| Timestamp accuracy | For a correct finding, how close is `timestamp_s` to the annotated ground truth? | Tight tolerance (seconds, not minutes) — a compliance analyst needs to jump directly to the moment, not scrub a window. |
| Schema conformance rate | Fraction of responses that validate against the schema in [schemas.md](schemas.md) on first synthesis attempt (before retry) | Tracked as a leading indicator of agent reliability, independent of content accuracy. |
| Confidence calibration | Do findings with `confidence: 0.9` turn out correct ~90% of the time, aggregated over the golden set? | A miscalibrated confidence score is as dangerous as a wrong answer, since analysts will learn to trust or distrust the number. |

## 3. Grading methodology

- **Automated grading against the golden set** runs on every change to the ingestion pipeline, the agent's prompts/tools, or the underlying Bedrock model version — this is a regression suite, not a one-time benchmark.
- **LLM-as-judge** is used for the free-text portion that survives into `claim` (semantic equivalence to the annotated ground truth, not exact string match), followed by:
- **Human audit sampling**: a fixed percentage of production `findings` (weighted toward low-confidence and high-materiality categories) is reviewed by compliance analysts on a rolling basis, and disagreements are fed back into the golden dataset — the evaluation set is a living artifact, not a fixed benchmark that goes stale.

## 4. Production monitoring

- **Schema-validation failure rate** and **evidence_complete: false rate** are tracked as live SLIs — a rising trend in either indicates the agent is struggling against current corpus size or query complexity before a human notices in the output.
- **Analyst override/dispute rate**: when an analyst marks a finding as incorrect in the review UI, that event is logged with the query and evidence trail, feeding both the golden set and an alerting threshold for accuracy drift.
- **Drift detection**: because the underlying Bedrock model can be upgraded independently of the application, every model-version change is gated on a full golden-set run before rollout, with results compared against the previous version's baseline rather than an absolute pass/fail bar.

## 5. Why this satisfies the RFP's evaluation ask

The RFP's requirement was "an evaluation strategy to prove accuracy" — the operative word is *prove*. Every metric above is measured against SME-annotated ground truth, re-run on every material change, and continuously refreshed from production disagreements, so accuracy claims are backed by a reproducible number rather than a demo.
