# AI Architecture Proposal: Sightline for Apex Financial Group

**To:** Marcus Vance, VP of Operational Risk & Intelligence, Apex Financial Group
**From:** AI Solutions Architecture Team
**Re:** Enterprise AI Video Intelligence & Compliance Pipeline

## Executive summary

Apex records over 3,000 hours of video monthly and currently relies on manual review that costs upwards of $1.5M per year, takes weeks per cycle, and still misses violations. **Sightline** is a production-grade, AWS-native pipeline that ingests that archive automatically, converts it into structured and searchable intelligence, and answers compliance analysts' natural-language questions with strictly schema-validated, source-cited, auditable output — eliminating hallucination risk and making review time-to-answer a matter of seconds, not weeks.

This document maps Sightline's design directly onto the four requirements in your request. Full technical detail lives in the linked documents.

## 1. Automated ingestion

Video lands in Amazon S3 and is automatically routed through an event-driven pipeline (`transcriber-job`, `embedding-job`) coordinated by Amazon EventBridge:

- **Audio → precise, speaker-labeled, timestamped transcription** via Amazon Transcribe.
- Full architecture and every AWS service involved: [architecture.md](architecture.md). Exact step-by-step sequence: [data-flow.md](data-flow.md).

**Current scope and what's next:** this phase of the build prioritized shipping the audio/text pipeline — upload through transcription, embedding, and semantic search — as a solid, fully working slice, rather than a wider pipeline that's partially built. The visual half of your request (intelligent frame sampling and on-screen summaries) is not implemented yet; it's the next planned addition, and the schema and agent design (see [schemas.md](schemas.md), [agent-orchestration.md](agent-orchestration.md)) were kept deliberately extensible so it can be added without a breaking change to either.

## 2. Autonomous query agent

Analysts ask questions in plain language through `app-service`, a Next.js application on AWS App Runner that also serves the analyst-facing UI — for example, *"Identify all instances where an advisor discussed unapproved crypto assets in Q2, return the precise video timestamps."* The agent decomposes the question into a plan (date filtering, semantic transcript search, synthesis) and executes each step as a distinct tool call against Amazon Bedrock, Amazon S3 Vectors, and Amazon RDS, rather than attempting it as a single retrieval. Once visual sampling exists, the same loop extends to cross-modal questions like the on-screen-summary example in your original request.

Full mechanics, tool catalog, and the grounding controls that keep it from guessing: [agent-orchestration.md](agent-orchestration.md).

## 3. Strict schema and source verification

Every agent response is validated against a JSON Schema before it ever reaches an analyst: exact `video_id`, `timestamp_s`, a tightly scoped `claim`, a `confidence` score, and a `source` type for every finding, with no free-text field for the model to editorialize in. A response that fails validation is retried internally, never surfaced. An empty `findings` array is a first-class, valid answer, so the system is not incentivized to invent a violation to fill the field. Full schemas: [schemas.md](schemas.md).

Accuracy is not asserted — it's measured against an SME-annotated golden dataset with recall, precision, timestamp-accuracy, and confidence-calibration metrics re-run on every pipeline or model change, plus rolling human audit of production output. Full methodology: [evaluation-strategy.md](evaluation-strategy.md).

## 4. Enterprise cost and reliability

The pipeline is fully event-driven and serverless on the ingestion side (AWS Lambda) and autoscaled on the query side (AWS App Runner), so capacity — and cost — tracks actual usage rather than provisioned peak. Every downstream AWS dependency (Transcribe, Bedrock, S3 Vectors) sits behind retry-with-backoff and a circuit breaker, so a transient or degraded downstream service produces a fast, typed failure instead of cascading latency or runaway spend. Full design: [cost-and-reliability.md](cost-and-reliability.md).

## Infrastructure diagram

See [architecture.md](architecture.md) for the annotated diagram and VPC-by-VPC service breakdown (source file: [Infra.drawio](Infra.drawio)). In summary: `VPC App` (the query agent, on AWS App Runner) is the only externally reachable boundary, exposed directly on its own managed HTTPS endpoint; ingestion runs in an isolated `VPC Jobs`; managed AI services are isolated in `VPC AI`; and the system of record — Amazon S3, Amazon RDS, Amazon EventBridge — lives in `VPC Storage`, reachable only by the tiers that need it.

## Next steps

We propose a scoped pilot against one month of Apex's recorded advisory-session archive, benchmarked directly against the manual process it replaces: time-to-answer, analyst hours saved, and — measured against a jointly-built golden dataset — recall and precision on a defined set of violation categories your compliance team selects.
