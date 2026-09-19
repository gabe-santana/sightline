"""Thin Postgres helpers standing in for the Amazon RDS access layer.

Connects two ways, matching config.py's two modes:

- Real AWS: fetches the RDS-managed master credentials from Secrets Manager
  (cached at module scope, so it's fetched once per warm Lambda execution
  environment, not once per invocation) and connects with keyword
  arguments -- not a hand-built "postgresql://user:pass@host/db" URL, since
  RDS-generated passwords contain characters (`#`, `?`, `:`, ...) that
  would corrupt a URL built by naive string interpolation.
- Local dev: connects with the plain DATABASE_URL docker-compose sets.

Every function opens a short-lived connection and retries on start-up races
(Postgres isn't guaranteed to accept connections the instant a dependent
container starts, and matters less but is harmless for real RDS too),
since this is a small data-access layer, not a pooled production one. A
real deployment at higher volume would front RDS with RDS Proxy instead of
opening one connection per Lambda invocation.
"""
import json
import time
import uuid
from contextlib import contextmanager
from typing import Optional

import boto3
import psycopg2
import psycopg2.extras

from . import config

psycopg2.extras.register_uuid()

_db_credentials_cache: Optional[dict] = None


def _get_db_credentials() -> dict:
    global _db_credentials_cache
    if _db_credentials_cache is None:
        client = boto3.client("secretsmanager", region_name=config.AWS_REGION)
        response = client.get_secret_value(SecretId=config.DATABASE_SECRET_ARN)
        _db_credentials_cache = json.loads(response["SecretString"])
    return _db_credentials_cache


def _connect():
    if config.DATABASE_SECRET_ARN:
        credentials = _get_db_credentials()
        return psycopg2.connect(
            host=config.DATABASE_HOST,
            port=config.DATABASE_PORT,
            dbname=config.DATABASE_NAME,
            user=credentials["username"],
            password=credentials["password"],
            sslmode="require",
        )
    if config.DATABASE_URL:
        return psycopg2.connect(config.DATABASE_URL)
    raise RuntimeError("neither DATABASE_SECRET_ARN nor DATABASE_URL is set")


@contextmanager
def get_conn(retries: int = 10, delay_s: float = 2.0):
    last_error = None
    for _ in range(retries):
        try:
            conn = _connect()
            conn.autocommit = True
            try:
                yield conn
            finally:
                conn.close()
            return
        except psycopg2.OperationalError as exc:
            last_error = exc
            time.sleep(delay_s)
    raise RuntimeError(f"could not connect to database after {retries} attempts") from last_error


# Mirrors docker/postgres/init.sql, which only runs against local dev's
# Postgres container -- real RDS has no init-script equivalent, so each
# Lambda creates this schema on cold start if it doesn't exist yet (see
# infra/README.md). Keep both in sync if the schema changes.
_SCHEMA_STATEMENTS = [
    """
    CREATE TABLE IF NOT EXISTS videos (
        video_id UUID PRIMARY KEY,
        s3_key TEXT NOT NULL UNIQUE,
        transcript_status TEXT NOT NULL DEFAULT 'pending'
            CHECK (transcript_status IN ('pending', 'transcribing', 'done', 'failed')),
        embedding_status TEXT NOT NULL DEFAULT 'pending'
            CHECK (embedding_status IN ('pending', 'done', 'failed')),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS transcript_segments (
        segment_id UUID PRIMARY KEY,
        video_id UUID NOT NULL REFERENCES videos (video_id) ON DELETE CASCADE,
        start_s NUMERIC NOT NULL,
        end_s NUMERIC NOT NULL,
        text TEXT NOT NULL,
        speaker TEXT,
        confidence NUMERIC
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_transcript_segments_video_id ON transcript_segments (video_id)",
]


def ensure_schema() -> None:
    with get_conn() as conn, conn.cursor() as cur:
        for statement in _SCHEMA_STATEMENTS:
            cur.execute(statement)


def ensure_video(video_id: uuid.UUID, s3_key: str) -> None:
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO videos (video_id, s3_key) VALUES (%s, %s) "
            "ON CONFLICT (video_id) DO NOTHING",
            (video_id, s3_key),
        )


def mark_status(video_id: uuid.UUID, column: str, value: str) -> None:
    assert column in {"transcript_status", "embedding_status"}
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            f"UPDATE videos SET {column} = %s, updated_at = now() WHERE video_id = %s",
            (value, video_id),
        )


def fetch_video_status(video_id: uuid.UUID) -> Optional[dict]:
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT transcript_status, embedding_status FROM videos WHERE video_id = %s",
            (video_id,),
        )
        row = cur.fetchone()
        return dict(row) if row else None


def insert_transcript_segments(video_id: uuid.UUID, segments: list[dict]) -> None:
    with get_conn() as conn, conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            "INSERT INTO transcript_segments "
            "(segment_id, video_id, start_s, end_s, text, speaker, confidence) VALUES %s",
            [
                (
                    s["segment_id"],
                    video_id,
                    s["start_s"],
                    s["end_s"],
                    s["text"],
                    s.get("speaker"),
                    s.get("confidence"),
                )
                for s in segments
            ],
        )


def fetch_videos_ready_for_embedding() -> list[uuid.UUID]:
    """Used only by local dev's polling local_runner.py -- production
    embedding-job is triggered directly by the transcript_ready event
    (see src/transcriber-job/handler.py) and processes one video_id from
    the event, not a sweep of the whole table."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT video_id FROM videos "
            "WHERE transcript_status = 'done' AND embedding_status = 'pending'"
        )
        return [row[0] for row in cur.fetchall()]


def fetch_transcript_segments(video_id: uuid.UUID) -> list[dict]:
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT segment_id, video_id, start_s, end_s, text, speaker, confidence "
            "FROM transcript_segments WHERE video_id = %s",
            (video_id,),
        )
        return [dict(row) for row in cur.fetchall()]
