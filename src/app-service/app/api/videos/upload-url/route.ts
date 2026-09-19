import { randomUUID } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { config } from "@/lib/config";
import { ensureVideo } from "@/lib/db";

function presigningS3Client(): S3Client {
  return new S3Client({
    region: config.awsRegion,
    // Credentials come from App Runner's instance role (see
    // aws_iam_role.app_service_instance in infra/iam.tf) via the default
    // provider chain -- nothing to configure here.
    //
    // Newer SDK versions default to attaching a CRC32 checksum to presigned
    // PutObject URLs, which then only validates if the uploader computes the
    // exact same checksum. Since the uploader here is just a plain HTTP PUT
    // (curl, a browser), turn that default off.
    requestChecksumCalculation: "WHEN_REQUIRED",
  });
}

export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  const filename = body?.filename;
  if (typeof filename !== "string" || filename.length === 0) {
    return NextResponse.json({ error: "filename is required" }, { status: 400 });
  }

  const videoId = randomUUID();
  const s3Key = `videos/${videoId}/${filename}`;

  const uploadUrl = await getSignedUrl(
    presigningS3Client(),
    new PutObjectCommand({ Bucket: config.bucketName, Key: s3Key }),
    { expiresIn: 3600 }
  );

  await ensureVideo(videoId, s3Key);

  return NextResponse.json({ video_id: videoId, s3_key: s3Key, upload_url: uploadUrl });
}
