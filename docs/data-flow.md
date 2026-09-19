# Data flow

Two independent flows share the same storage layer: **ingestion** (asynchronous, triggered by upload) and **query** (synchronous, triggered by an analyst).

## 1. Ingestion flow

Three EventBridge-driven hops, not a single trigger fanning out — `transcriber-job` runs twice (once per hop it owns), and `embedding-job` is invoked directly by a domain event, not a schedule or a poll:

```mermaid
sequenceDiagram
    participant Ops as Compliance / Ops system
    participant S3 as Amazon S3
    participant EB as Amazon EventBridge
    participant Tr as transcriber-job
    participant Transcribe as Amazon Transcribe
    participant Emb as embedding-job
    participant Bedrock as Amazon Bedrock
    participant SV as Amazon S3 Vectors
    participant RDS as Amazon RDS

    Ops->>S3: Upload MP4 asset (videos/{video_id}/...)
    S3->>EB: ObjectCreated event
    EB->>Tr: invoke (hop 1: key prefix "videos/")
    Tr->>Transcribe: StartTranscriptionJob(output -> transcribe-output/{video_id}.json)
    Tr->>RDS: mark transcript_status = "transcribing"
    Note over Transcribe: runs asynchronously, tens of seconds to minutes
    Transcribe->>S3: writes result JSON
    S3->>EB: ObjectCreated event
    EB->>Tr: invoke (hop 2: key prefix "transcribe-output/")
    Tr->>S3: read result JSON
    Tr->>Tr: group words into segments (sentence / speaker-change / length breaks)
    Tr->>RDS: insert transcript_segments, mark transcript_status = "done"
    Tr->>EB: put_events(source="sightline.transcriber", detail-type="transcript_ready")
    EB->>Emb: invoke (hop 3: transcript_ready)
    Emb->>RDS: read transcript segments for video_id
    Emb->>Bedrock: embed(text) per segment
    Bedrock-->>Emb: vectors
    Emb->>SV: put_vectors(vector, metadata: video_id, timestamp_s, text)
    Emb->>RDS: mark embedding_status = "done"
```

Notes:

- Each hop has its own EventBridge rule, retry policy, and dead-letter queue (see [cost-and-reliability.md](cost-and-reliability.md)) — a failure in one hop doesn't block or duplicate the others.
- The "videos/" and "transcribe-output/" key prefixes are what let a single Lambda (`transcriber-job`) own both ends of the Transcribe hand-off without the two event patterns matching each other's events.
- `embedding-job` never polls or scans for work: `transcript_ready` carries the exact `video_id` to process, so one event does one video, not a sweep of the whole table.
- A video's status (`transcript_status`: `pending → transcribing → done | failed`; `embedding_status`: `pending → done | failed`) is queryable in RDS at every stage, which is what makes SLA reporting and stuck-job alerting possible.

## 2. Query flow

```mermaid
sequenceDiagram
    participant Analyst
    participant API as app-service (App Runner, Next.js) — query agent
    participant Bedrock as Amazon Bedrock
    participant SV as Amazon S3 Vectors
    participant RDS as Amazon RDS
    participant S3 as Amazon S3

    Analyst->>API: POST /api/query {natural language question} (App Runner's public HTTPS domain)
    API->>Bedrock: decompose question into sub-tasks (planning step)
    loop for each sub-task
        API->>SV: query_vectors(embedding, metadata filter)
        SV-->>API: candidate segments + distance scores
        API->>RDS: resolve segment -> video_id, timestamp, source metadata
        RDS-->>API: structured evidence
    end
    API->>Bedrock: synthesize evidence into schema-constrained answer
    Bedrock-->>API: draft JSON response
    API->>API: validate against JSON Schema (schemas.md); reject/retry on failure
    API-->>Analyst: 200 OK, schema-valid JSON response
```

Notes:

- Every claim in the final answer must trace back to a specific `video_id` + `timestamp` retrieved from RDS/S3 Vectors in an earlier step — the synthesis step is not permitted to introduce evidence it didn't retrieve. See [agent-orchestration.md](agent-orchestration.md) for how this is enforced.
- If schema validation fails, the API retries the synthesis step (bounded retry count) before returning a typed error rather than an unvalidated answer — the system never returns free-form prose to the analyst.
- There is no visual-confirmation step (no sampled frames exist to fetch) — see the scope note in [architecture.md](architecture.md).
