"""Local stand-in for Amazon Transcribe.

Amazon Transcribe has no official local emulator (LocalStack does not
support it), and actually running speech-to-text is outside the scope of
emulating the AWS wiring. This service returns a fixed, deterministic
transcript for any request so the rest of the pipeline (persistence,
embedding, search, the query agent) can be exercised end to end locally.
Point TRANSCRIBE_ENDPOINT at a real STT service (or real Amazon Transcribe,
via infra/) to get real transcripts.
"""
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="mock-transcribe")


class TranscribeRequest(BaseModel):
    video_id: str
    s3_key: str


CANNED_SEGMENTS = [
    {"start_s": 0.0, "end_s": 8.5, "text": "Good morning, thanks for joining today's advisory session.", "speaker": "Speaker 1", "confidence": 0.97},
    {"start_s": 8.5, "end_s": 19.2, "text": "Let's walk through your portfolio allocation for this quarter.", "speaker": "Speaker 1", "confidence": 0.95},
    {"start_s": 19.2, "end_s": 31.0, "text": "I wanted to ask about diversifying into some crypto assets we discussed.", "speaker": "Speaker 2", "confidence": 0.93},
]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/transcribe")
def transcribe(request: TranscribeRequest):
    return {"video_id": request.video_id, "s3_key": request.s3_key, "segments": CANNED_SEGMENTS}
