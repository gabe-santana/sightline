"""Environment-driven configuration shared by the Python Lambda jobs.

Two deployment modes, distinguished by which variables are actually set
(not by a separate flag):

- **Local dev** (docker-compose): TRANSCRIBE_ENDPOINT / BEDROCK_ENDPOINT /
  OPENSEARCH_URL / DATABASE_URL are set explicitly by docker-compose.yml,
  pointing at the mock services and local Postgres/OpenSearch.
- **Real AWS**: none of those are set. DATABASE_SECRET_ARN + DATABASE_HOST
  are set instead (see infra/lambda.tf), and handlers call Amazon
  Transcribe, Amazon Bedrock, and Amazon S3 Vectors directly via boto3.

Real AWS deployments also won't set AWS_ENDPOINT_URL, so boto3 will talk
to real AWS endpoints instead of LocalStack with no code changes required.
"""
import os


AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
AWS_ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")  # e.g. http://localstack:4566 for local dev

BUCKET_NAME = os.environ.get("BUCKET_NAME", "sightline-videos")
TRANSCRIBER_QUEUE_NAME = os.environ.get("TRANSCRIBER_QUEUE_NAME", "transcriber-job-queue")

# --- Database: Secrets Manager (real AWS) or a plain URL (local dev) ------
DATABASE_SECRET_ARN = os.environ.get("DATABASE_SECRET_ARN")
DATABASE_HOST = os.environ.get("DATABASE_HOST")
DATABASE_PORT = int(os.environ.get("DATABASE_PORT", "5432"))
DATABASE_NAME = os.environ.get("DATABASE_NAME", "sightline")
DATABASE_URL = os.environ.get("DATABASE_URL")  # local dev only; None on real AWS

# --- Semantic index: S3 Vectors (real AWS) or OpenSearch (local dev) ------
S3VECTORS_BUCKET_NAME = os.environ.get("S3VECTORS_BUCKET_NAME")
S3VECTORS_INDEX_NAME = os.environ.get("S3VECTORS_INDEX_NAME")
OPENSEARCH_URL = os.environ.get("OPENSEARCH_URL")  # local dev only; None on real AWS
OPENSEARCH_INDEX = os.environ.get("OPENSEARCH_INDEX", "sightline-embeddings")

# --- Transcribe / Bedrock: real AWS via boto3, or REST mocks locally ------
TRANSCRIBE_ENDPOINT = os.environ.get("TRANSCRIBE_ENDPOINT")  # local dev only; None on real AWS
BEDROCK_ENDPOINT = os.environ.get("BEDROCK_ENDPOINT")  # local dev only; None on real AWS
TRANSCRIBE_OUTPUT_PREFIX = os.environ.get("TRANSCRIBE_OUTPUT_PREFIX", "transcribe-output/")
EMBEDDING_MODEL_ID = os.environ.get("EMBEDDING_MODEL_ID", "amazon.titan-embed-text-v2:0")

EMBEDDING_POLL_INTERVAL_S = float(os.environ.get("EMBEDDING_POLL_INTERVAL_S", "5"))

