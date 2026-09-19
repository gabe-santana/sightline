-- Local stand-in for the Amazon RDS schema described in docs/schemas.md.
-- embedding-job is gated on transcript_status = 'done' (see docs/data-flow.md);
-- in production it's triggered directly by the transcript_ready event, not a poll.

CREATE TABLE IF NOT EXISTS videos (
    video_id UUID PRIMARY KEY,
    s3_key TEXT NOT NULL UNIQUE,
    transcript_status TEXT NOT NULL DEFAULT 'pending' CHECK (transcript_status IN ('pending', 'transcribing', 'done', 'failed')),
    embedding_status TEXT NOT NULL DEFAULT 'pending' CHECK (embedding_status IN ('pending', 'done', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS transcript_segments (
    segment_id UUID PRIMARY KEY,
    video_id UUID NOT NULL REFERENCES videos (video_id) ON DELETE CASCADE,
    start_s NUMERIC NOT NULL,
    end_s NUMERIC NOT NULL,
    text TEXT NOT NULL,
    speaker TEXT,
    confidence NUMERIC
);

CREATE INDEX IF NOT EXISTS idx_transcript_segments_video_id ON transcript_segments (video_id);
