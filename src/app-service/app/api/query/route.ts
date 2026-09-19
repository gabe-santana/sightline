import { randomUUID } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import { converse, embed } from "@/lib/bedrock";
import { searchTranscripts, TranscriptMatch } from "@/lib/s3vectors";
import { validateComplianceQueryResponse } from "@/lib/schema";

/**
 * The query agent from docs/agent-orchestration.md. This is a single
 * retrieval-then-synthesize pass, not the full bounded multi-step
 * tool-calling loop the doc describes (there's only one tool --
 * search_transcripts -- implemented so far; get_video_metadata and
 * get_transcript_window aren't wired in yet). The grounding controls that
 * matter most today are still enforced: synthesis only ever runs against
 * retrieved evidence, and the model never supplies its own video_id or
 * timestamp_s -- those come straight from the vector search hit, not the
 * model's response, so a hallucinated citation is structurally impossible.
 */

interface RelevancePlan {
  relevant_indices: number[];
  claims: Record<string, string>;
  evidence_complete: boolean;
}

function buildPrompt(question: string, evidence: TranscriptMatch[]): string {
  const excerpts = evidence
    .map((item, i) => `[${i}] video_id=${item.video_id} timestamp_s=${item.timestamp_s}\n"${item.text}"`)
    .join("\n\n");

  return [
    "You are a compliance analyst assistant reviewing transcript excerpts retrieved by semantic search.",
    `Question: "${question}"`,
    "",
    "Excerpts:",
    excerpts || "(none retrieved)",
    "",
    "Decide which excerpts, if any, genuinely support an answer to the question. For each one you " +
      "include, write a one-sentence claim describing what it shows -- strictly grounded in that " +
      "excerpt's own text, never adding information the excerpt doesn't contain.",
    "",
    "Respond with ONLY a JSON object, no other text, in exactly this shape:",
    '{"relevant_indices": [<int>, ...], "claims": {"<index>": "<claim text>"}, "evidence_complete": <true|false>}',
    "",
    "If none of the excerpts are relevant, respond with " +
      '{"relevant_indices": [], "claims": {}, "evidence_complete": true}.',
  ].join("\n");
}

function extractJson(text: string): unknown {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) {
    throw new Error("no JSON object found in model output");
  }
  return JSON.parse(text.slice(start, end + 1));
}

function isRelevancePlan(value: unknown): value is RelevancePlan {
  return (
    !!value &&
    typeof value === "object" &&
    Array.isArray((value as RelevancePlan).relevant_indices) &&
    typeof (value as RelevancePlan).claims === "object"
  );
}

async function synthesizePlan(question: string, evidence: TranscriptMatch[]): Promise<RelevancePlan> {
  const prompt = buildPrompt(question, evidence);
  let lastError: unknown;

  // One retry on a malformed response, matching the "reject and retry
  // synthesis if invalid" control in docs/agent-orchestration.md.
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const raw = await converse(
        attempt === 0
          ? prompt
          : `${prompt}\n\nYour previous reply was not valid JSON in the required shape. Respond again with ONLY that JSON object.`
      );
      const parsed = extractJson(raw);
      if (isRelevancePlan(parsed)) {
        return parsed;
      }
      lastError = new Error("model response did not match the expected relevance-plan shape");
    } catch (err) {
      lastError = err;
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  const question = body?.question;
  if (typeof question !== "string" || question.length === 0) {
    return NextResponse.json({ error: "question is required" }, { status: 400 });
  }

  const queryVector = await embed(question);
  const evidence = await searchTranscripts(queryVector, 5);

  let findings: {
    video_id: string;
    timestamp_s: number;
    claim: string;
    confidence: number;
    source: "transcript";
  }[] = [];
  let evidenceComplete = true;

  if (evidence.length > 0) {
    try {
      const plan = await synthesizePlan(question, evidence);
      findings = plan.relevant_indices
        .filter((i) => Number.isInteger(i) && i >= 0 && i < evidence.length)
        .map((i) => ({
          video_id: evidence[i].video_id,
          timestamp_s: evidence[i].timestamp_s,
          claim: plan.claims[String(i)] ?? evidence[i].text,
          confidence: Math.max(0, Math.min(1, evidence[i].score)),
          source: "transcript" as const,
        }));
      evidenceComplete = plan.evidence_complete ?? true;
    } catch (err) {
      return NextResponse.json(
        { error: "synthesis failed", details: err instanceof Error ? err.message : String(err) },
        { status: 502 }
      );
    }
  }

  const response = {
    query_id: randomUUID(),
    question,
    findings,
    evidence_complete: evidenceComplete,
  };

  const { valid, errors } = validateComplianceQueryResponse(response);
  if (!valid) {
    return NextResponse.json(
      { error: "response failed schema validation", details: errors },
      { status: 502 }
    );
  }

  return NextResponse.json(response);
}
