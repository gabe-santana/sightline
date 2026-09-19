# --- Lambda execution roles: one per job, scoped to exactly what each ----
# --- job touches (see docs/architecture.md's per-job responsibilities) ---

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# transcriber-job: starts Amazon Transcribe jobs from the upload event,
# then -- invoked again when Transcribe's own output lands in S3 -- reads
# that result, writes transcript_segments, and publishes the
# transcript_ready event embedding-job reacts to.
resource "aws_iam_role" "transcriber_job" {
  name               = "${local.name}-transcriber-job"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "transcriber_job_vpc" {
  role       = aws_iam_role.transcriber_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "transcriber_job" {
  statement {
    sid       = "ReadTranscribeOutput"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.videos.arn}/*"]
  }
  statement {
    # See handler.py's _normalize_for_transcribe: a container Transcribe
    # doesn't accept (MKV, most notably) gets its audio extracted and
    # re-uploaded here before Transcribe ever sees it.
    sid       = "WriteNormalizedAudio"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.videos.arn}/videos-normalized/*"]
  }
  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.postgres.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "Transcribe"
    actions   = ["transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob", "transcribe:ListTranscriptionJobs"]
    resources = ["*"] # Transcribe jobs don't support resource-level ARN scoping.
  }
  statement {
    sid       = "PublishTranscriptReady"
    actions   = ["events:PutEvents"]
    resources = ["arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"]
  }
}

resource "aws_iam_role_policy" "transcriber_job" {
  name   = "${local.name}-transcriber-job"
  role   = aws_iam_role.transcriber_job.id
  policy = data.aws_iam_policy_document.transcriber_job.json
}

# embedding-job: reads RDS (via app code, not IAM), calls Bedrock, writes
# to S3 Vectors. No S3 access needed -- it never touches the raw video.
resource "aws_iam_role" "embedding_job" {
  name               = "${local.name}-embedding-job"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "embedding_job_vpc" {
  role       = aws_iam_role.embedding_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "embedding_job" {
  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.postgres.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "Bedrock"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"] # narrow to specific model ARNs once the embedding model is chosen.
  }
  statement {
    sid     = "S3Vectors"
    actions = ["s3vectors:PutVectors", "s3vectors:GetIndex"]
    resources = [
      aws_s3vectors_vector_bucket.main.vector_bucket_arn,
      aws_s3vectors_index.transcript_segments.index_arn,
    ]
  }
}

resource "aws_iam_role_policy" "embedding_job" {
  name   = "${local.name}-embedding-job"
  role   = aws_iam_role.embedding_job.id
  policy = data.aws_iam_policy_document.embedding_job.json
}

# --- app-service (App Runner) ---------------------------------------------

data "aws_iam_policy_document" "apprunner_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["tasks.apprunner.amazonaws.com"]
    }
  }
}

# The role the *running* app-service container assumes -- needs the DB
# secret, Bedrock, S3 Vectors, and S3 (its presigned-upload-URL requests
# are only authorized against S3 at request time, using this role).
resource "aws_iam_role" "app_service_instance" {
  name               = "${local.name}-app-service-instance"
  assume_role_policy = data.aws_iam_policy_document.apprunner_tasks_assume_role.json
}

data "aws_iam_policy_document" "app_service_instance" {
  statement {
    sid       = "VideoBucketReadWrite"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.videos.arn}/*"]
  }
  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.postgres.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "Bedrock"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }
  statement {
    sid     = "S3Vectors"
    actions = ["s3vectors:QueryVectors", "s3vectors:GetVectors", "s3vectors:GetIndex"]
    resources = [
      aws_s3vectors_vector_bucket.main.vector_bucket_arn,
      aws_s3vectors_index.transcript_segments.index_arn,
    ]
  }
}

resource "aws_iam_role_policy" "app_service_instance" {
  name   = "${local.name}-app-service-instance"
  role   = aws_iam_role.app_service_instance.id
  policy = data.aws_iam_policy_document.app_service_instance.json
}

# Only used once app_service_image_repository_type = "ECR" -- the role App
# Runner itself assumes (not the running app) to pull the private image.
data "aws_iam_policy_document" "apprunner_build_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["build.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apprunner_ecr_access" {
  name               = "${local.name}-apprunner-ecr-access"
  assume_role_policy = data.aws_iam_policy_document.apprunner_build_assume_role.json
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr_access" {
  role       = aws_iam_role.apprunner_ecr_access.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}
