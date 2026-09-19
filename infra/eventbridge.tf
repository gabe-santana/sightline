# The pipeline is a chain of three EventBridge-driven hops, each with its
# own retry policy and dead-letter queue so a failure in one hop is
# retried/quarantined independently of the others (see
# docs/cost-and-reliability.md):
#
#   S3 upload  -> [on-video-uploaded]        -> transcriber-job (start Transcribe)
#   Transcribe -> [on-transcript-output]     -> transcriber-job (parse + publish transcript_ready)
#   transcriber-job -> [on-transcript-ready] -> embedding-job (embed + index)

# --- Hop 1: video uploaded -> start transcription -------------------------

resource "aws_cloudwatch_event_rule" "on_video_uploaded" {
  name        = "${local.name}-on-video-uploaded"
  description = "Starts a transcription job when a new video lands in S3."

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.videos.bucket] }
      object = { key = [{ prefix = "videos/" }] }
    }
  })
}

resource "aws_sqs_queue" "video_uploaded_dlq" {
  name                      = "${local.name}-video-uploaded-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "video_uploaded_dlq" {
  statement {
    sid       = "AllowEventBridgeSendMessage"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.video_uploaded_dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.on_video_uploaded.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "video_uploaded_dlq" {
  queue_url = aws_sqs_queue.video_uploaded_dlq.id
  policy    = data.aws_iam_policy_document.video_uploaded_dlq.json
}

resource "aws_cloudwatch_event_target" "video_uploaded" {
  rule = aws_cloudwatch_event_rule.on_video_uploaded.name
  arn  = aws_lambda_function.transcriber_job.arn

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.video_uploaded_dlq.arn
  }
}

resource "aws_lambda_permission" "video_uploaded" {
  statement_id  = "AllowEventBridgeInvokeOnVideoUploaded"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transcriber_job.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.on_video_uploaded.arn
}

# --- Hop 2: Transcribe output landed -> parse + publish transcript_ready --

resource "aws_cloudwatch_event_rule" "on_transcript_output_created" {
  name        = "${local.name}-on-transcript-output-created"
  description = "Fires when Amazon Transcribe writes a completed job's result to S3."

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.videos.bucket] }
      object = { key = [{ prefix = "transcribe-output/" }] }
    }
  })
}

resource "aws_sqs_queue" "transcript_output_dlq" {
  name                      = "${local.name}-transcript-output-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "transcript_output_dlq" {
  statement {
    sid       = "AllowEventBridgeSendMessage"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.transcript_output_dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.on_transcript_output_created.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "transcript_output_dlq" {
  queue_url = aws_sqs_queue.transcript_output_dlq.id
  policy    = data.aws_iam_policy_document.transcript_output_dlq.json
}

resource "aws_cloudwatch_event_target" "transcript_output_created" {
  rule = aws_cloudwatch_event_rule.on_transcript_output_created.name
  arn  = aws_lambda_function.transcriber_job.arn

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.transcript_output_dlq.arn
  }
}

resource "aws_lambda_permission" "transcript_output_created" {
  statement_id  = "AllowEventBridgeInvokeOnTranscriptOutput"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transcriber_job.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.on_transcript_output_created.arn
}

# --- Hop 3: transcript_ready (custom domain event) -> embed + index ------

resource "aws_cloudwatch_event_rule" "on_transcript_ready" {
  name        = "${local.name}-on-transcript-ready"
  description = "Triggers embedding-job as soon as transcriber-job finishes a video -- no polling."

  event_pattern = jsonencode({
    source      = ["sightline.transcriber"]
    detail-type = ["transcript_ready"]
  })
}

resource "aws_sqs_queue" "transcript_ready_dlq" {
  name                      = "${local.name}-transcript-ready-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "transcript_ready_dlq" {
  statement {
    sid       = "AllowEventBridgeSendMessage"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.transcript_ready_dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.on_transcript_ready.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "transcript_ready_dlq" {
  queue_url = aws_sqs_queue.transcript_ready_dlq.id
  policy    = data.aws_iam_policy_document.transcript_ready_dlq.json
}

resource "aws_cloudwatch_event_target" "transcript_ready" {
  rule = aws_cloudwatch_event_rule.on_transcript_ready.name
  arn  = aws_lambda_function.embedding_job.arn

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.transcript_ready_dlq.arn
  }
}

resource "aws_lambda_permission" "transcript_ready" {
  statement_id  = "AllowEventBridgeInvokeOnTranscriptReady"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.embedding_job.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.on_transcript_ready.arn
}
