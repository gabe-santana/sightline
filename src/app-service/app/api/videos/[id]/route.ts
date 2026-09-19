import { NextResponse } from "next/server";
import { fetchVideo } from "@/lib/db";

export async function GET(_request: Request, { params }: { params: { id: string } }) {
  const video = await fetchVideo(params.id);
  if (!video) {
    return NextResponse.json({ error: "video not found" }, { status: 404 });
  }
  return NextResponse.json(video);
}
