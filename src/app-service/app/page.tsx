"use client";

import { useState } from "react";

interface UploadResult {
  video_id: string;
  s3_key: string;
  upload_url: string;
}

interface VideoStatus {
  transcript_status: string;
  embedding_status: string;
}

interface Finding {
  video_id: string;
  timestamp_s: number;
  claim: string;
  confidence: number;
  source: string;
}

interface QueryResponse {
  query_id: string;
  question: string;
  findings: Finding[];
  evidence_complete: boolean;
}

const boxStyle: React.CSSProperties = {
  background: "#f4f4f4",
  padding: "1rem",
  marginTop: "1rem",
  borderRadius: 4,
  overflowX: "auto",
};

export default function HomePage() {
  const [file, setFile] = useState<File | null>(null);
  const [uploadResult, setUploadResult] = useState<UploadResult | null>(null);
  const [videoStatus, setVideoStatus] = useState<VideoStatus | null>(null);
  const [uploading, setUploading] = useState(false);

  const [question, setQuestion] = useState("");
  const [queryResult, setQueryResult] = useState<QueryResponse | null>(null);
  const [querying, setQuerying] = useState(false);

  const [error, setError] = useState<string | null>(null);

  async function handleUpload() {
    if (!file) return;
    setUploading(true);
    setError(null);
    try {
      const uploadUrlResponse = await fetch("/api/videos/upload-url", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ filename: file.name }),
      });
      const result: UploadResult = await uploadUrlResponse.json();
      const putResponse = await fetch(result.upload_url, { method: "PUT", body: file });
      if (!putResponse.ok) throw new Error(`upload to S3 failed: ${putResponse.status}`);
      setUploadResult(result);
      setVideoStatus(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "upload failed");
    } finally {
      setUploading(false);
    }
  }

  async function handleCheckStatus() {
    if (!uploadResult) return;
    setError(null);
    const response = await fetch(`/api/videos/${uploadResult.video_id}`);
    if (!response.ok) {
      setError("video not found yet -- ingestion may not have started");
      return;
    }
    setVideoStatus(await response.json());
  }

  async function handleQuery() {
    if (!question) return;
    setQuerying(true);
    setError(null);
    try {
      const response = await fetch("/api/query", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error ?? "query failed");
      setQueryResult(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : "query failed");
    } finally {
      setQuerying(false);
    }
  }

  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "2rem", fontFamily: "sans-serif" }}>
      <h1>Sightline</h1>
      <p>
        Minimal analyst UI over app-service&apos;s own API routes -- see{" "}
        <code>docs/agent-orchestration.md</code>.
      </p>

      {error && <p style={{ color: "crimson" }}>{error}</p>}

      <section style={{ marginTop: "2rem" }}>
        <h2>1. Upload a video</h2>
        <input type="file" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
        <button onClick={handleUpload} disabled={!file || uploading} style={{ marginLeft: "1rem" }}>
          {uploading ? "Uploading..." : "Upload"}
        </button>
        {uploadResult && (
          <div>
            <p>
              <code>video_id: {uploadResult.video_id}</code>
            </p>
            <button onClick={handleCheckStatus}>Check ingestion status</button>
            {videoStatus && <pre style={boxStyle}>{JSON.stringify(videoStatus, null, 2)}</pre>}
          </div>
        )}
      </section>

      <section style={{ marginTop: "2rem" }}>
        <h2>2. Ask a question</h2>
        <input
          type="text"
          value={question}
          onChange={(e) => setQuestion(e.target.value)}
          placeholder="Did the advisor discuss crypto assets?"
          style={{ width: "100%", padding: "0.5rem", boxSizing: "border-box" }}
        />
        <button onClick={handleQuery} disabled={!question || querying} style={{ marginTop: "0.5rem" }}>
          {querying ? "Asking..." : "Ask"}
        </button>
        {queryResult && <pre style={boxStyle}>{JSON.stringify(queryResult, null, 2)}</pre>}
      </section>
    </main>
  );
}
