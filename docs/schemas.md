# Schemas

Sightline enforces structure at two points: what ingestion writes into the system of record, and what the agent is allowed to return to an analyst. Both are validated with JSON Schema; a payload that fails validation is never persisted (ingestion) or never returned (query).

## Ingestion records (Amazon RDS / S3 Vectors payloads)

### Transcript segment

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "TranscriptSegment",
  "type": "object",
  "required": ["video_id", "segment_id", "start_s", "end_s", "text", "speaker"],
  "properties": {
    "video_id": { "type": "string", "format": "uuid" },
    "segment_id": { "type": "string", "format": "uuid" },
    "start_s": { "type": "number", "minimum": 0 },
    "end_s": { "type": "number", "minimum": 0 },
    "text": { "type": "string" },
    "speaker": { "type": "string" },
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
  }
}
```

## Agent query response

This is the contract the query agent's synthesis step must satisfy before a response leaves the API. It is deliberately strict: no free-text answer field, no claim without a source.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ComplianceQueryResponse",
  "type": "object",
  "required": ["query_id", "question", "findings", "evidence_complete"],
  "properties": {
    "query_id": { "type": "string", "format": "uuid" },
    "question": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["video_id", "timestamp_s", "claim", "confidence", "source"],
        "properties": {
          "video_id": { "type": "string", "format": "uuid" },
          "timestamp_s": { "type": "number", "minimum": 0 },
          "claim": {
            "type": "string",
            "description": "The specific statement this finding supports, scoped tightly to what the evidence shows."
          },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
          "source": {
            "type": "string",
            "enum": ["transcript"],
            "description": "Single-valued today (transcript-only retrieval); reserved as an enum so a visual_frame source can be added later without a breaking schema change."
          }
        },
        "additionalProperties": false
      }
    },
    "evidence_complete": {
      "type": "boolean",
      "description": "False if the agent hit its step/time budget before it could be certain the corpus was fully searched — signals the analyst that this result may be partial."
    }
  },
  "additionalProperties": false
}
```

Design choices worth calling out:

- **`findings` is an array, and an empty array is valid.** "No violations found" must be representable without the model inventing a finding to fill the field.
- **`additionalProperties: false` at every object level.** The model cannot smuggle a narrative explanation field in alongside the structured data — if it isn't in the schema, it's rejected and the synthesis step retries.
- **`evidence_complete`** exists so a budget-limited answer is visibly partial rather than silently indistinguishable from an exhaustive one — critical for an auditable compliance tool.
- **`source` is an enum**, not a free-text description, so downstream dashboards can filter/aggregate by evidence type without NLP. It's single-valued today because there's no visual-frame sampling stage yet (see [architecture.md](architecture.md)) — kept as an enum, not a hardcoded literal, so adding `visual_frame` / `transcript+visual_frame` later doesn't change the shape of existing data.
