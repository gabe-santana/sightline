resource "aws_s3_bucket" "videos" {
  bucket = local.video_bucket_name

  # Lets `terraform destroy` actually tear this down even if it isn't
  # empty (e.g. lambda-builds/ deployment zips, test uploads) instead of
  # failing partway through -- see infra/README.md's destroy-between-
  # sessions cost note.
  force_destroy = true

  tags = { Name = local.video_bucket_name }
}

resource "aws_s3_bucket_versioning" "videos" {
  bucket = aws_s3_bucket.videos.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "videos" {
  bucket                  = aws_s3_bucket.videos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Matches the cost model in docs/cost-and-reliability.md: raw assets tier
# down to cheaper storage classes once they're no longer being actively
# processed.
resource "aws_s3_bucket_lifecycle_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id

  rule {
    id     = "tier-down-raw-assets"
    status = "Enabled"

    filter {
      prefix = "videos/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # Normalized audio (see transcriber-job/handler.py's
  # _normalize_for_transcribe) is a disposable intermediate for Transcribe
  # to read once -- nothing downstream ever reads it again after that, so
  # there's no reason to keep it around.
  rule {
    id     = "expire-normalized-audio"
    status = "Enabled"

    filter {
      prefix = "videos-normalized/"
    }

    expiration {
      days = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# Native S3 -> EventBridge integration: every ObjectCreated event in this
# bucket is published to the account's default event bus, where the rule
# in eventbridge.tf picks it up. No SNS/SQS glue required.
resource "aws_s3_bucket_notification" "videos" {
  bucket      = aws_s3_bucket.videos.id
  eventbridge = true
}
