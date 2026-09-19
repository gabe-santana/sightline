# Local development

`docker/docker-compose.yml` stands up a local equivalent of every AWS resource in [architecture.md](architecture.md), so the ingestion and query pipeline in [data-flow.md](data-flow.md) can be exercised on a laptop with no AWS account.

**Status note:** this stack was last verified end to end against an earlier layout that included an `observer-job` (removed — see the scope note in [architecture.md](architecture.md)) and a scheduled-poll `embedding-job` (now event-driven in production). `transcriber-job` and `embedding-job` still run locally the same way; `_handle_local_mock` in `transcriber-job` and the local sweep loop in `embedding-job` were kept deliberately simple rather than mirroring production's new 3-hop event chain (see the fidelity table below) — it has **not** been re-run end to end since. `app-service` no longer has a local path at all: it's now real, AWS-only code (Secrets Manager, Amazon S3 Vectors, Amazon Bedrock — see the fidelity table), so exercising the two ingestion jobs locally and then querying through `app-service` in the same run isn't possible anymore. Treat "docker compose up" as covering ingestion only, not the full pipeline, until this is revisited.

## Repository layout this stack builds from

This is a monorepo. Each Lambda job and the app service are independent, self-contained units under `src/`; Python code shared between the jobs, and the JSON Schema shared across the whole monorepo, live in `packages/` (a sibling of `src/`, not inside it):

```
packages/common_py/      Shared Python: config, Postgres/Secrets Manager access, the S3 key convention
packages/schemas/        The canonical ComplianceQueryResponse JSON Schema (see schemas.md)
src/transcriber-job/     handler.py (the real Lambda code) + local_runner.py (local-dev-only SQS adapter)
src/embedding-job/       handler.py (per-event in production, sweeps Postgres locally) + local_runner.py
src/app-service/         Next.js app: app/api/* are the query agent's routes, app/page.tsx is the analyst UI
```

`handler.py` in each job is exactly what would run as the deployed Lambda. `local_runner.py` exists only so docker-compose has something to run locally; it is never deployed. Both jobs are plain zip-packaged Lambdas in production (see [infra/lambda.tf](../infra/lambda.tf)) — no container images anywhere in this pipeline.

## What's a faithful emulation vs. a mock

| AWS resource | Local stand-in | Fidelity |
|---|---|---|
| Amazon S3, EventBridge, SQS | [LocalStack](https://www.localstack.cloud/) | Real AWS APIs — the native S3 → EventBridge integration and the EventBridge rule routing uploads to transcriber-job's queue are configured exactly as they would be against real AWS. |
| Amazon RDS | Postgres | RDS *is* managed Postgres — talking to a plain `postgres` container over the wire protocol is a faithful stand-in for the app code. |
| Amazon S3 Vectors | OpenSearch (the open-source project) | **Not the real service** — production uses Amazon S3 Vectors (see [infra/s3vectors.tf](../infra/s3vectors.tf)), which has no local emulator. OpenSearch's `match` query approximates vector similarity search well enough to exercise the pipeline locally, but the actual API shape (`PutVectors`/`QueryVectors`, metadata filters) differs from what production code calls. |
| `transcriber-job` (Lambda, invoked directly by EventBridge in production, twice per video — see [data-flow.md](data-flow.md)) | `handler.py`'s `_handle_local_mock` path, run via `local_runner.py`, which polls an SQS queue | Local dev only exercises the first hop's shape: one synchronous call to `mock-transcribe`, not the real start-job/parse-output split. The real two-hop dispatch logic (`start_transcription` / `process_transcription_result`) only runs against real AWS, gated by whether `TRANSCRIBE_ENDPOINT` is set. |
| `embedding-job` (Lambda, invoked directly by the `transcript_ready` event in production — no polling) | `handler.py`'s local sweep path, called in a loop by `local_runner.py` | Production reacts to one event per video; local dev polls Postgres for `transcript_status = 'done' AND embedding_status = 'pending'` on an interval instead, since there's no `transcript_ready` event wiring in the local EventBridge setup. |
| `app-service` (AWS App Runner) | *Not currently runnable locally* | `app-service`'s code now talks to Amazon RDS (via Secrets Manager), Amazon S3 Vectors, and Amazon Bedrock directly (see `src/app-service/lib/`) with no local fallback — it needs real AWS credentials and real resources (from `infra/`) to run at all, including against `docker compose`. |
| Amazon Transcribe | `mock-transcribe` (FastAPI) | **Not a real emulator** — no official local Transcribe emulator exists. Returns a fixed canned transcript for any input so the rest of the pipeline has real data to work with. |
| Amazon Bedrock | `mock-bedrock` (FastAPI) | **Not a real emulator** — no official local Bedrock emulator exists. `/embed` returns a deterministic hash-based vector (not semantically meaningful); `/converse` echoes retrieved evidence back in the [`ComplianceQueryResponse`](schemas.md) shape rather than actually reasoning. |

The consequence: ingestion, storage, retrieval plumbing, and schema enforcement are all genuinely exercised. The *agent's reasoning*, *real speech-to-text*, and the *asynchronous Transcribe hand-off* are not — swap `TRANSCRIBE_ENDPOINT` / `BEDROCK_ENDPOINT` for real AWS endpoints (drop `AWS_ENDPOINT_URL` and give the containers real AWS credentials) to get real transcripts, real reasoning, and the real event chain with no application-code changes.

## Running it

```bash
docker compose -f docker/docker-compose.yml up -d --build
```

This builds and starts, in dependency order: `localstack` (bootstraps the S3 bucket, EventBridge rule, and SQS queue via [docker/localstack/init/ready.d/01-init-aws.sh](../docker/localstack/init/ready.d/01-init-aws.sh) as soon as it's healthy), `postgres` (schema loaded from [docker/postgres/init.sql](../docker/postgres/init.sql)), `opensearch`, `mock-transcribe`, `mock-bedrock`, the two job workers, and `app-service`.

Check everything is healthy:

```bash
docker compose -f docker/docker-compose.yml ps
```

## Exercising the pipeline

**Option A — the UI.** Open [http://localhost:8080](http://localhost:8080): upload any file, check its ingestion status, then ask a question (try *"Did the advisor discuss crypto assets?"*).

**Option B — curl**, for scripting or CI:

```bash
curl -s -X POST http://localhost:8080/api/videos/upload-url \
  -H "Content-Type: application/json" \
  -d '{"filename":"advisory-session.mp4"}'
# => {"video_id": "...", "s3_key": "videos/<video_id>/advisory-session.mp4", "upload_url": "..."}

curl -X PUT --upload-file ./any-file.mp4 "<upload_url from above>"
```

The PUT triggers the same path a real upload would: S3 → EventBridge → transcriber-worker → Postgres; `embedding-worker` picks it up on its next poll and indexes it into OpenSearch.

Poll status until every stage reads `done`:

```bash
curl -s http://localhost:8080/api/videos/<video_id>
# => {"transcript_status": "done", "embedding_status": "done", ...}
```

Ask a question, matching the RFP's example query:

```bash
curl -s -X POST http://localhost:8080/api/query \
  -H "Content-Type: application/json" \
  -d '{"question":"Did the advisor discuss crypto assets?"}'
```

Returns a schema-valid [`ComplianceQueryResponse`](schemas.md) citing the exact `video_id` and `timestamp_s` the canned transcript segment came from. A question that matches nothing returns `"findings": []` — a valid answer, not an error, per the design in [schemas.md](schemas.md).

## Inspecting the emulated resources directly

```bash
# S3 bucket / EventBridge rule / SQS queue (including its DLQ)
docker compose -f docker/docker-compose.yml exec localstack awslocal s3 ls s3://sightline-videos --recursive
docker compose -f docker/docker-compose.yml exec localstack awslocal sqs list-queues

# Postgres (RDS stand-in)
docker compose -f docker/docker-compose.yml exec postgres psql -U sightline -d sightline -c "select * from videos;"

# OpenSearch
curl -s http://localhost:9200/sightline-embeddings/_search?pretty
```

## Tearing down

```bash
docker compose -f docker/docker-compose.yml down -v   # -v also drops the Postgres/OpenSearch/LocalStack volumes
```
