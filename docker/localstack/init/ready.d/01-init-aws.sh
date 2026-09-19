#!/usr/bin/env bash
# Bootstraps the local stand-ins for the AWS resources in docs/architecture.md:
# an S3 bucket wired to EventBridge exactly like real S3 -> EventBridge notifications,
# and an EventBridge rule that routes uploads to transcriber-job's queue (with a DLQ),
# mirroring the retry/DLQ design in docs/cost-and-reliability.md.
#
# Runs automatically once when the LocalStack container reports ready
# (see https://docs.localstack.cloud/references/init-hooks/).
set -euo pipefail

REGION="us-east-1"
BUCKET="sightline-videos"

echo "== Sightline local AWS bootstrap =="

awslocal s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
echo "created bucket: $BUCKET"

# Native S3 -> EventBridge integration (same feature real AWS uses; no SNS/Lambda glue needed).
awslocal s3api put-bucket-notification-configuration \
  --bucket "$BUCKET" \
  --notification-configuration '{"EventBridgeConfiguration": {}}'
echo "enabled EventBridge notifications on: $BUCKET"

# Dead-letter queue, created first so the main queue can reference its ARN.
TRANSCRIBER_DLQ_URL=$(awslocal sqs create-queue --queue-name transcriber-job-dlq --query QueueUrl --output text)
TRANSCRIBER_DLQ_ARN=$(awslocal sqs get-queue-attributes --queue-url "$TRANSCRIBER_DLQ_URL" --attribute-names QueueArn --query "Attributes.QueueArn" --output text)

# Main queue: 3 delivery attempts before a message is moved to its DLQ.
TRANSCRIBER_QUEUE_URL=$(awslocal sqs create-queue --queue-name transcriber-job-queue \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$TRANSCRIBER_DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" \
  --query QueueUrl --output text)
TRANSCRIBER_QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "$TRANSCRIBER_QUEUE_URL" --attribute-names QueueArn --query "Attributes.QueueArn" --output text)
echo "created queue: transcriber-job-queue (+ DLQ)"

# A video upload triggers transcriber-job, which starts an Amazon Transcribe job
# (real AWS) or a synchronous mock-transcribe call (local, see
# transcriber-job/handler.py's _handle_local_mock) -- either way, this single
# queue is where the local worker container polls from. Production's second and
# third hops (Transcribe output -> transcript_ready -> embedding-job, see
# docs/data-flow.md) don't exist locally: the local mock finishes synchronously
# and embedding-worker discovers ready videos by polling Postgres instead
# (see docker-compose.yml's embedding-worker and src/embedding-job/local_runner.py).
awslocal events put-rule \
  --name on-video-uploaded \
  --event-pattern "{\"source\":[\"aws.s3\"],\"detail-type\":[\"Object Created\"],\"detail\":{\"bucket\":{\"name\":[\"$BUCKET\"]}}}"

awslocal events put-targets --rule on-video-uploaded --targets \
  "Id=transcriber-job,Arn=$TRANSCRIBER_QUEUE_ARN"
echo "created rule: on-video-uploaded -> [transcriber-job-queue]"

# Note: real AWS also requires an SQS queue policy granting events.amazonaws.com
# permission to SendMessage (scoped to this rule's ARN). LocalStack does not enforce
# resource policies by default, so it's omitted here to keep local bootstrap simple —
# the real deployment (infra/) must still define it.

echo "== Sightline local AWS bootstrap complete =="
