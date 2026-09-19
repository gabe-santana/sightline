"""Local stand-in for Amazon Bedrock.

Bedrock has no official local emulator, and running a real foundation
model is outside the scope of emulating the AWS wiring. This service
exposes just enough surface for the rest of the pipeline to run locally:

- POST /embed: a deterministic pseudo-embedding (hash-seeded, not
  semantically meaningful) so embedding-job and OpenSearch indexing can
  be exercised without a real model.
- POST /converse: echoes retrieved evidence back in the
  ComplianceQueryResponse shape from docs/schemas.md, standing in for the
  agent's synthesis step described in docs/agent-orchestration.md.

Point BEDROCK_ENDPOINT at a real reasoning backend (Ollama, or real Amazon
Bedrock via infra/) to get real answers instead of an echo.
"""
import hashlib
import random

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="mock-bedrock")

EMBEDDING_DIM = 128


class EmbedRequest(BaseModel):
    text: str


class EvidenceItem(BaseModel):
    video_id: str
    timestamp_s: float
    text: str
    score: float


class ConverseRequest(BaseModel):
    question: str
    evidence: list[EvidenceItem] = []


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/embed")
def embed(request: EmbedRequest):
    seed = int(hashlib.sha256(request.text.encode("utf-8")).hexdigest(), 16) % (2**32)
    rng = random.Random(seed)
    vector = [rng.uniform(-1.0, 1.0) for _ in range(EMBEDDING_DIM)]
    return {"embedding": vector}


@app.post("/converse")
def converse(request: ConverseRequest):
    findings = [
        {
            "video_id": item.video_id,
            "timestamp_s": item.timestamp_s,
            "claim": item.text,
            "confidence": round(min(max(item.score, 0.0), 1.0), 2),
            "source": "transcript",
        }
        for item in request.evidence
    ]
    return {"findings": findings, "evidence_complete": True}
