"""embedding-job (AWS Lambda) -- see docs/architecture.md.

In production, triggered directly by transcriber-job's `transcript_ready`
event (see infra/eventbridge.tf and src/transcriber-job/handler.py) --
one event, one video, no polling. Locally, there's no EventBridge rule
wiring docker-compose's containers together that way, so
local_runner.py instead calls this in a loop and it sweeps Postgres for
any video with transcript_status = 'done' and embedding_status =
'pending' (see db.fetch_videos_ready_for_embedding).

Two independent choices, each with its own real-vs-local switch:
- **Embedding model**: Amazon Bedrock (real) or mock-bedrock's /embed
  (local, see docker/mock-bedrock) -- selected by BEDROCK_ENDPOINT.
- **Vector index**: Amazon S3 Vectors (real) or OpenSearch (local, no S3
  Vectors emulator exists) -- selected by S3VECTORS_BUCKET_NAME vs.
  OPENSEARCH_URL. These are independent of each other and of which mode
  the embedding call is in.

Real embedding-job would also embed sampled visual-frame descriptions;
that's not implemented -- there is no visual-sampling stage in this
pipeline right now (see docs/architecture.md).
"""
import json
import logging
import uuid

import boto3
import requests
from opensearchpy import OpenSearch, helpers

from common_py import config, db

logging.basicConfig(level=logging.INFO, format="%(asctime)s embedding-job %(message)s")
log = logging.getLogger("embedding-job")

_bedrock = None
_s3vectors = None
_opensearch = None

OPENSEARCH_INDEX_MAPPING = {
    "settings": {"index": {"knn": True}},
    "mappings": {
        "properties": {
            "video_id": {"type": "keyword"},
            "segment_id": {"type": "keyword"},
            "timestamp_s": {"type": "float"},
            "text": {"type": "text"},
            "embedding": {"type": "knn_vector", "dimension": 1024},
        }
    },
}


def bedrock_client():
    global _bedrock
    if _bedrock is None:
        _bedrock = boto3.client("bedrock-runtime", region_name=config.AWS_REGION)
    return _bedrock


def s3vectors_client():
    global _s3vectors
    if _s3vectors is None:
        _s3vectors = boto3.client("s3vectors", region_name=config.AWS_REGION)
    return _s3vectors


def opensearch_client() -> OpenSearch:
    global _opensearch
    if _opensearch is None:
        _opensearch = OpenSearch(hosts=[config.OPENSEARCH_URL], use_ssl=False, verify_certs=False)
        if not _opensearch.indices.exists(config.OPENSEARCH_INDEX):
            _opensearch.indices.create(config.OPENSEARCH_INDEX, body=OPENSEARCH_INDEX_MAPPING)
    return _opensearch


def embed(text: str) -> list[float]:
    if config.BEDROCK_ENDPOINT:
        response = requests.post(
            f"{config.BEDROCK_ENDPOINT}/embed", json={"text": text}, timeout=30
        )
        response.raise_for_status()
        return response.json()["embedding"]

    response = bedrock_client().invoke_model(
        modelId=config.EMBEDDING_MODEL_ID,
        body=json.dumps({"inputText": text, "dimensions": 1024, "normalize": True}),
        contentType="application/json",
        accept="application/json",
    )
    return json.loads(response["body"].read())["embedding"]


def index_segments(video_id, segments: list[dict], vectors: list[list[float]]) -> None:
    if config.S3VECTORS_BUCKET_NAME:
        s3vectors_client().put_vectors(
            vectorBucketName=config.S3VECTORS_BUCKET_NAME,
            indexName=config.S3VECTORS_INDEX_NAME,
            vectors=[
                {
                    "key": str(segment["segment_id"]),
                    "data": {"float32": vector},
                    "metadata": {
                        "video_id": str(video_id),
                        "timestamp_s": float(segment["start_s"]),
                        "text": segment["text"],
                    },
                }
                for segment, vector in zip(segments, vectors)
            ],
        )
        return

    actions = [
        {
            "_index": config.OPENSEARCH_INDEX,
            "_id": str(segment["segment_id"]),
            "_source": {
                "video_id": str(video_id),
                "segment_id": str(segment["segment_id"]),
                "timestamp_s": float(segment["start_s"]),
                "text": segment["text"],
                "embedding": vector,
            },
        }
        for segment, vector in zip(segments, vectors)
    ]
    helpers.bulk(opensearch_client(), actions)


def process_video(video_id) -> None:
    segments = db.fetch_transcript_segments(video_id)
    if segments:
        vectors = [embed(segment["text"]) for segment in segments]
        index_segments(video_id, segments, vectors)
    db.mark_status(video_id, "embedding_status", "done")
    log.info("indexed %d segments for video %s", len(segments), video_id)


def _handle_local_sweep() -> dict:
    video_ids = db.fetch_videos_ready_for_embedding()
    processed, failed = 0, 0
    for video_id in video_ids:
        try:
            process_video(video_id)
            processed += 1
        except Exception:  # noqa: BLE001 - keep processing other videos on one failure
            log.exception("failed to embed video %s", video_id)
            db.mark_status(video_id, "embedding_status", "failed")
            failed += 1

    return {"processed": processed, "failed": failed}


def handler(event: dict, context) -> dict:
    if config.BEDROCK_ENDPOINT or config.OPENSEARCH_URL:
        return _handle_local_sweep()

    video_id = uuid.UUID(event["detail"]["video_id"])
    process_video(video_id)
    return {"processed": 1, "failed": 0}
