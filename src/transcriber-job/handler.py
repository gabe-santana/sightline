"""transcriber-job (AWS Lambda) -- see docs/architecture.md.

Amazon Transcribe is asynchronous: a batch job takes anywhere from tens of
seconds to several minutes for a long recording, far longer than makes
sense to block a Lambda invocation waiting on it. So this function has two
distinct entry paths, both reached through the same handler because
EventBridge delivers both as the same S3 "Object Created" event shape,
distinguished only by the key prefix:

1. `videos/...` (the upload event) -> start a transcription job and
   return immediately.
2. `transcribe-output/...` (Transcribe's own result landing in S3,
   forwarded by a second EventBridge rule -- see infra/eventbridge.tf) ->
   parse the result into transcript segments, save them, and publish a
   `transcript_ready` domain event. embedding-job is triggered directly
   by that event (its own EventBridge rule) -- there's no polling on
   either side of this handoff.

Locally (TRANSCRIBE_ENDPOINT set), neither of this applies: local dev has
no second queue for a completion event, so it keeps the single-shot
synchronous call to mock-transcribe (see docker/mock-transcribe), and
embedding-job's local_runner.py polls Postgres on an interval instead of
reacting to a real event.
"""
import json
import logging
import os
import shutil
import subprocess
import uuid

import boto3
import imageio_ffmpeg
import requests

from common_py import config, db
from common_py.video_key import parse_video_id

logging.basicConfig(level=logging.INFO, format="%(asctime)s transcriber-job %(message)s")
log = logging.getLogger("transcriber-job")

# Runs once per cold start (module import), not per invocation. Real RDS has
# no init-script equivalent to docker/postgres/init.sql, so this is what
# actually creates the schema in production -- see db.ensure_schema.
db.ensure_schema()

# imageio-ffmpeg ships a static ffmpeg binary as wheel data (see
# requirements.txt) -- the same "download a prebuilt manylinux wheel, skip
# compilation" trick infra/lambda.tf already uses for psycopg2-binary, so
# this needs no Docker/container image either. The build step that produces
# the deployment zip runs on Windows, which doesn't reliably carry the Unix
# executable bit through the zip the way a Linux build would -- and
# `/var/task` (where the deployment package is mounted) is read-only at
# runtime, so a missing bit can't be fixed with chmod in place. This copies
# the binary into /tmp (the one writable path) and sets it there instead,
# once per cold start.
_FFMPEG_EXE = "/tmp/ffmpeg-transcriber-job"
if not os.path.exists(_FFMPEG_EXE):
    shutil.copy(imageio_ffmpeg.get_ffmpeg_exe(), _FFMPEG_EXE)
    os.chmod(_FFMPEG_EXE, 0o755)

# Amazon Transcribe's supported MediaFormat values (StartTranscriptionJob) --
# anything else (MKV, most notably, one of the RFP's stated input formats)
# needs its audio pulled out into one of these first. See
# _normalize_for_transcribe below.
_TRANSCRIBE_SUPPORTED_FORMATS = {"mp3", "mp4", "wav", "flac", "amr", "ogg", "webm", "m4a"}
_NORMALIZED_PREFIX = "videos-normalized/"
_NORMALIZED_FORMAT = "m4a"

_transcribe = None
_s3 = None
_events = None


def transcribe_client():
    global _transcribe
    if _transcribe is None:
        _transcribe = boto3.client("transcribe", region_name=config.AWS_REGION)
    return _transcribe


def s3_client():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=config.AWS_REGION)
    return _s3


def events_client():
    global _events
    if _events is None:
        _events = boto3.client("events", region_name=config.AWS_REGION)
    return _events


def _job_name(video_id: uuid.UUID) -> str:
    # TranscriptionJobName is unique per account/region -- deterministic
    # from video_id so a redelivered upload event doesn't start a second
    # job for the same video.
    return f"sightline-{video_id}"


def _output_key(video_id: uuid.UUID) -> str:
    return f"{config.TRANSCRIBE_OUTPUT_PREFIX}{video_id}.json"


def _extension(s3_key: str) -> str:
    return s3_key.rsplit(".", 1)[-1].lower() if "." in s3_key else ""


def _normalize_for_transcribe(video_id: uuid.UUID, s3_key: str) -> str:
    """Extracts the audio track from a container Transcribe doesn't accept
    (MKV, most notably) into an M4A file it does, and uploads that instead
    of the original -- Transcribe only ever reads the audio anyway, so
    re-encoding the video stream would be pure waste.

    ffmpeg reads directly from a presigned GET URL rather than downloading
    the source first, so only the (much smaller) audio output ever touches
    /tmp -- what keeps this practical for hour-long recordings within a
    Lambda's ephemeral storage and timeout budget. The original object in
    `videos/` is left untouched; this uploads a second, derived object
    under `videos-normalized/` that only transcriber-job ever reads.
    """
    source_url = s3_client().generate_presigned_url(
        "get_object",
        Params={"Bucket": config.BUCKET_NAME, "Key": s3_key},
        ExpiresIn=3600,
    )
    local_path = f"/tmp/{video_id}.{_NORMALIZED_FORMAT}"  # noqa: S108 - Lambda's only writable path

    try:
        subprocess.run(
            [
                _FFMPEG_EXE,
                "-y",
                "-i", source_url,
                "-vn",  # drop video entirely -- Transcribe never looks at it
                "-acodec", "aac",
                "-b:a", "128k",
                local_path,
            ],
            check=True,
            capture_output=True,
            timeout=780,  # leaves headroom under the Lambda's own 840s timeout (see infra/lambda.tf)
        )
    except subprocess.CalledProcessError as exc:
        log.error("ffmpeg failed to normalize %s: %s", s3_key, exc.stderr.decode(errors="replace"))
        raise

    normalized_key = f"{_NORMALIZED_PREFIX}{video_id}.{_NORMALIZED_FORMAT}"
    s3_client().upload_file(local_path, config.BUCKET_NAME, normalized_key)
    os.remove(local_path)
    return normalized_key


def start_transcription(video_id: uuid.UUID, s3_key: str) -> None:
    media_key, media_format = s3_key, None
    if _extension(s3_key) not in _TRANSCRIBE_SUPPORTED_FORMATS:
        media_key = _normalize_for_transcribe(video_id, s3_key)
        media_format = _NORMALIZED_FORMAT

    media_uri = f"s3://{config.BUCKET_NAME}/{media_key}"
    try:
        transcribe_client().start_transcription_job(
            TranscriptionJobName=_job_name(video_id),
            Media={"MediaFileUri": media_uri},
            # Only set explicitly for a normalized file -- for anything
            # already in a supported container (MP4, most commonly),
            # Transcribe infers the format from the S3 key's extension.
            **({"MediaFormat": media_format} if media_format else {}),
            LanguageCode="en-US",
            OutputBucketName=config.BUCKET_NAME,
            OutputKey=_output_key(video_id),
            Settings={"ShowSpeakerLabels": True, "MaxSpeakerLabels": 4},
        )
    except transcribe_client().exceptions.ConflictException:
        # A job with this name already exists -- an EventBridge redelivery
        # of the same upload event, not a new video. Nothing to do.
        pass
    db.mark_status(video_id, "transcript_status", "transcribing")


def _speaker_at(speaker_labels: dict, start_time: str) -> str | None:
    for segment in speaker_labels.get("segments", []):
        for item in segment.get("items", []):
            if item.get("start_time") == start_time:
                return item.get("speaker_label")
    return None


_MAX_SEGMENT_WORDS = 40


def _group_into_segments(transcribe_result: dict) -> list[dict]:
    """Groups Transcribe's word-by-word output into sentence-ish segments,
    breaking on sentence-ending punctuation, a speaker change, or a length
    cap -- whichever comes first. Transcribe's batch API returns individual
    words/punctuation, not pre-grouped segments, so this is the minimum
    real logic needed to get rows shaped like docs/schemas.md's
    TranscriptSegment out of it."""
    items = transcribe_result["results"]["items"]
    speaker_labels = transcribe_result["results"].get("speaker_labels", {})

    def render(pending: list[dict]) -> dict:
        text = "".join(
            w["content"] if w["type"] == "punctuation" else f" {w['content']}" for w in pending
        ).strip()
        confidences = [w["confidence"] for w in pending]
        starts = [w["start_s"] for w in pending if w["start_s"] is not None]
        ends = [w["end_s"] for w in pending if w["end_s"] is not None]
        return {
            "start_s": starts[0] if starts else 0.0,
            "end_s": ends[-1] if ends else 0.0,
            "text": text,
            "speaker": next((w["speaker"] for w in pending if w["speaker"]), None),
            "confidence": sum(confidences) / len(confidences) if confidences else None,
        }

    segments: list[dict] = []
    pending: list[dict] = []
    current_speaker: str | None = None

    for item in items:
        item_type = item["type"]
        content = item["alternatives"][0]["content"]
        confidence = float(item["alternatives"][0].get("confidence", 0.0))
        item_speaker = (
            _speaker_at(speaker_labels, item["start_time"]) if "start_time" in item else None
        )

        if pending and item_speaker is not None and current_speaker not in (None, item_speaker):
            segments.append(render(pending))
            pending = []

        pending.append(
            {
                "type": item_type,
                "content": content,
                "confidence": confidence,
                "start_s": float(item["start_time"]) if item_type == "pronunciation" else None,
                "end_s": float(item["end_time"]) if item_type == "pronunciation" else None,
                "speaker": item_speaker,
            }
        )
        if item_speaker is not None:
            current_speaker = item_speaker

        ends_sentence = item_type == "punctuation" and content in (".", "?", "!")
        if ends_sentence or len(pending) >= _MAX_SEGMENT_WORDS:
            segments.append(render(pending))
            pending = []
            current_speaker = None

    if pending:
        segments.append(render(pending))

    return [s for s in segments if s["text"]]


def publish_transcript_ready(video_id: uuid.UUID) -> None:
    events_client().put_events(
        Entries=[
            {
                "Source": "sightline.transcriber",
                "DetailType": "transcript_ready",
                "Detail": json.dumps({"video_id": str(video_id)}),
            }
        ]
    )


def process_transcription_result(output_key: str) -> None:
    prefix_len = len(config.TRANSCRIBE_OUTPUT_PREFIX)
    video_id = uuid.UUID(output_key[prefix_len:].removesuffix(".json"))

    response = s3_client().get_object(Bucket=config.BUCKET_NAME, Key=output_key)
    result = json.loads(response["Body"].read())

    segments = _group_into_segments(result)
    for segment in segments:
        segment["segment_id"] = uuid.uuid4()

    db.insert_transcript_segments(video_id, segments)
    db.mark_status(video_id, "transcript_status", "done")
    publish_transcript_ready(video_id)


def _handle_local_mock(event: dict) -> None:
    detail = event["detail"]
    s3_key = detail["object"]["key"]
    video_id = parse_video_id(s3_key)

    db.ensure_video(video_id, s3_key)

    response = requests.post(
        f"{config.TRANSCRIBE_ENDPOINT}/transcribe",
        json={"video_id": str(video_id), "s3_key": s3_key},
        timeout=30,
    )
    response.raise_for_status()
    segments = response.json()["segments"]
    for segment in segments:
        segment["segment_id"] = uuid.uuid4()

    db.insert_transcript_segments(video_id, segments)
    db.mark_status(video_id, "transcript_status", "done")


def handler(event: dict, context) -> None:
    if config.TRANSCRIBE_ENDPOINT:
        return _handle_local_mock(event)

    detail = event["detail"]
    s3_key = detail["object"]["key"]

    if s3_key.startswith(config.TRANSCRIBE_OUTPUT_PREFIX):
        process_transcription_result(s3_key)
    else:
        video_id = parse_video_id(s3_key)
        db.ensure_video(video_id, s3_key)
        start_transcription(video_id, s3_key)
