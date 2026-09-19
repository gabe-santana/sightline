# Cost and reliability

The RFP's bar is explicit: a two-hour video should cost **cents, not tens of dollars**, and the pipeline needs "strict retry logic and circuit breakers." This document covers both.

## Cost model (per 2-hour video, order-of-magnitude)

| Stage | Driver | Behavior that keeps it cheap |
|---|---|---|
| `transcriber-job` + Amazon Transcribe | Audio duration | Transcribe is billed per second of audio, independent of anything else — a 2-hour video is a fixed, small, predictable line item. |
| `embedding-job` + Amazon Bedrock | Number of transcript segments | Cost scales with *transcript length*, not video length or resolution — a 2-hour recording that's mostly silence or small talk produces fewer segments (and costs less) than one dense with compliance-relevant discussion. |
| Amazon S3 Vectors | Vectors stored + queried | Pay for vectors stored and queries made, not a running cluster — there's no idle-node cost the way there is with a hosted search cluster. |
| Amazon RDS / S3 | Storage | Flat, small per-video metadata and artifact footprint; standard S3 storage-class tiering applies to raw assets after processing. |

The compounding effect: every cost in this pipeline is a function of *audio duration* and *transcript volume*, both bounded and predictable per video — there is currently no per-frame or per-pixel cost anywhere, since there is no visual-processing stage (see the scope note in [architecture.md](architecture.md)). That also means the RFP's "why is this expensive" risk — per-frame vision-model calls on long, mostly-static footage — doesn't exist in this implementation yet, precisely because that capability isn't built.

**Why S3 Vectors instead of a hosted search cluster:** the semantic index was originally designed around Amazon OpenSearch Service, which is a genuinely capable vector store but bills for a running cluster whether or not it's handling traffic — a fixed cost floor that doesn't track the RFP's "cost scales with usage" requirement. Amazon S3 Vectors (verified directly against a live AWS account, including a real put/query round-trip with a metadata filter) offers the same metadata-filtered vector similarity search Sightline's retrieval needs, with sub-second query latency, at cost that scales with vectors stored and queried rather than a provisioned node. See [infra/README.md](../infra/README.md) for the cost comparison and [infra/s3vectors.tf](../infra/s3vectors.tf) for the resource definitions.

## Reliability

### Retry logic

- The ingestion pipeline is three EventBridge-driven hops (video uploaded → transcript output created → transcript ready — see [data-flow.md](data-flow.md)), each with its own retry policy and dead-letter queue, so a transient failure at one hop (e.g., a Transcribe throttling error) is retried with exponential backoff without re-triggering or blocking the others.
- `embedding-job` is invoked directly by the `transcript_ready` event carrying a specific `video_id` — there's no scan-and-retry-everything behavior; a failed embedding attempt only affects that one video's DLQ entry.
- Query-side tool calls (S3 Vectors, Bedrock) inside the agent loop use bounded retries with jittered exponential backoff, distinct from the agent's own step budget — a transient AWS API error is not treated the same as "no evidence found."

### Circuit breakers

- Calls from `app-service` (App Runner) to Amazon Bedrock and Amazon S3 Vectors are wrapped in a circuit breaker: after a threshold of consecutive failures, the breaker opens and the API fails fast with a typed "service degraded" response instead of piling up latency and cost on a downstream outage.
- The same pattern applies to `transcriber-job`'s calls to Amazon Transcribe — an open breaker pauses that job's EventBridge consumption rather than accumulating a retry storm against a struggling service.
- Breakers are per-downstream-dependency, so a Bedrock-side incident degrades only the reasoning/embedding path, not transcript ingestion or metadata reads.

### Idempotency

- Both jobs are keyed by `video_id` and safe to re-run: `transcriber-job`'s `StartTranscriptionJob` call uses a deterministic job name derived from `video_id`, so a redelivered upload event hits AWS's own `ConflictException` instead of starting a duplicate job; `embedding-job` re-indexing overwrites vectors by segment ID rather than duplicating them. This means retries — automatic or operator-triggered — never produce duplicate findings or double-billed embedding calls.

### Predictable scaling

- Ingestion (Jobs VPC) is Lambda-based and scales with upload volume automatically; a burst of 3,000 hours in a single day scales out horizontally without pre-provisioned capacity.
- The query path (App VPC) runs on App Runner, which autoscales on concurrent request volume, decoupling query-side capacity planning from ingestion-side load.
