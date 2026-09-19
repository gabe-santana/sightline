"""S3 key convention shared by app-service and every ingestion job.

Uploads are always written to `videos/{video_id}/<filename>`, so every
consumer of an S3 event can recover the video_id without a side lookup.
"""
import re
import uuid

_KEY_PATTERN = re.compile(r"^videos/(?P<video_id>[0-9a-fA-F-]{36})/")


def parse_video_id(s3_key: str) -> uuid.UUID:
    match = _KEY_PATTERN.match(s3_key)
    if not match:
        raise ValueError(
            f"S3 key '{s3_key}' does not match the expected 'videos/{{video_id}}/...' layout"
        )
    return uuid.UUID(match.group("video_id"))
