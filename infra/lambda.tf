# Both Lambdas are plain zip packages -- no container images, no Docker.
# psycopg2-binary needs a native extension built for Lambda's actual
# runtime (Amazon Linux, not whatever OS `terraform apply` runs on), which
# a bare `pip install` on a Windows/macOS dev machine can't produce.
# Compiling it under QEMU emulation for arm64 turned out to be unreliable
# (produced a binary with a mismatched Python ABI). The fix: skip
# compilation entirely and have pip download an already-built manylinux
# wheel for the target platform -- confirmed to exist and install cleanly
# for psycopg2-binary 2.9.10 on manylinux2014_aarch64 / cp313 before this
# was relied on here.
locals {
  common_py_files = fileset("${path.module}/../packages/common_py", "**")
  common_py_hash = sha256(join("", [
    for f in local.common_py_files : filesha256("${path.module}/../packages/common_py/${f}")
  ]))
}

resource "null_resource" "transcriber_job_build" {
  triggers = {
    requirements_hash = filesha256("${path.module}/../src/transcriber-job/requirements.txt")
    handler_hash      = filesha256("${path.module}/../src/transcriber-job/handler.py")
    common_py_hash    = local.common_py_hash
  }

  provisioner "local-exec" {
    interpreter = ["C:/Program Files/Git/bin/bash.exe", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf "${path.module}/.build/transcriber-job"
      mkdir -p "${path.module}/.build/transcriber-job"
      python -m pip install \
        --platform manylinux2014_aarch64 --implementation cp --python-version 3.13 \
        --only-binary=:all: --target "${path.module}/.build/transcriber-job" \
        -r "${path.module}/../src/transcriber-job/requirements.txt"
      cp -r "${path.module}/../packages/common_py" "${path.module}/.build/transcriber-job/common_py"
      cp "${path.module}/../src/transcriber-job/handler.py" "${path.module}/.build/transcriber-job/handler.py"
    EOT
  }
}

data "archive_file" "transcriber_job" {
  type        = "zip"
  source_dir  = "${path.module}/.build/transcriber-job"
  output_path = "${path.module}/.build/transcriber-job.zip"
  depends_on  = [null_resource.transcriber_job_build]
}

# Deployed via S3 rather than passed inline (filename/ZipFile): the ffmpeg
# binary imageio-ffmpeg bundles (see requirements.txt -- needed to
# normalize MKV and other formats Transcribe doesn't accept) pushes this
# zip to ~44MB compressed, uncomfortably close to the 50MB hard limit on
# an inline-uploaded deployment package. Routing through S3 only leaves
# the 250MB *unzipped* limit, which this is nowhere near (~85MB).
resource "aws_s3_object" "transcriber_job_zip" {
  bucket = aws_s3_bucket.videos.bucket
  key    = "lambda-builds/transcriber-job/${data.archive_file.transcriber_job.output_base64sha256}.zip"
  source = data.archive_file.transcriber_job.output_path
}

resource "null_resource" "embedding_job_build" {
  triggers = {
    requirements_hash = filesha256("${path.module}/../src/embedding-job/requirements.txt")
    handler_hash      = filesha256("${path.module}/../src/embedding-job/handler.py")
    common_py_hash    = local.common_py_hash
  }

  provisioner "local-exec" {
    interpreter = ["C:/Program Files/Git/bin/bash.exe", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf "${path.module}/.build/embedding-job"
      mkdir -p "${path.module}/.build/embedding-job"
      python -m pip install \
        --platform manylinux2014_aarch64 --implementation cp --python-version 3.13 \
        --only-binary=:all: --target "${path.module}/.build/embedding-job" \
        -r "${path.module}/../src/embedding-job/requirements.txt"
      cp -r "${path.module}/../packages/common_py" "${path.module}/.build/embedding-job/common_py"
      cp "${path.module}/../src/embedding-job/handler.py" "${path.module}/.build/embedding-job/handler.py"
    EOT
  }
}

data "archive_file" "embedding_job" {
  type        = "zip"
  source_dir  = "${path.module}/.build/embedding-job"
  output_path = "${path.module}/.build/embedding-job.zip"
  depends_on  = [null_resource.embedding_job_build]
}

# Same S3-based deployment as transcriber_job above, kept consistent
# between the two even though this one alone has more headroom under the
# 50MB inline-upload limit.
resource "aws_s3_object" "embedding_job_zip" {
  bucket = aws_s3_bucket.videos.bucket
  key    = "lambda-builds/embedding-job/${data.archive_file.embedding_job.output_base64sha256}.zip"
  source = data.archive_file.embedding_job.output_path
}

locals {
  lambda_env = {
    DATABASE_SECRET_ARN = aws_db_instance.postgres.master_user_secret[0].secret_arn
    DATABASE_HOST       = aws_db_instance.postgres.address
    DATABASE_PORT       = tostring(aws_db_instance.postgres.port)
    DATABASE_NAME       = var.db_name
    BUCKET_NAME         = aws_s3_bucket.videos.bucket
  }
}

resource "aws_lambda_function" "transcriber_job" {
  function_name = "${local.name}-transcriber-job"
  role          = aws_iam_role.transcriber_job.arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  architectures = [var.lambda_architecture]
  # Higher than embedding_job's: normalizing a long recording's audio track
  # for Transcribe (see handler.py's _normalize_for_transcribe) needs real
  # time and CPU on top of the usual API-call latency. 900s is Lambda's own
  # hard ceiling -- a recording long enough to need more than that would
  # need a fundamentally different approach (e.g. Step Functions or AWS
  # Elemental MediaConvert), not a bigger timeout.
  timeout     = 840
  memory_size = 1024

  s3_bucket        = aws_s3_bucket.videos.bucket
  s3_key           = aws_s3_object.transcriber_job_zip.key
  source_code_hash = data.archive_file.transcriber_job.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.jobs[*].id
    security_group_ids = [aws_security_group.jobs.id]
  }

  environment {
    variables = local.lambda_env
  }

  tags = { Name = "${local.name}-transcriber-job" }
}

resource "aws_lambda_function" "embedding_job" {
  function_name = "${local.name}-embedding-job"
  role          = aws_iam_role.embedding_job.arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  architectures = [var.lambda_architecture]
  timeout       = 120
  memory_size   = 512

  s3_bucket        = aws_s3_bucket.videos.bucket
  s3_key           = aws_s3_object.embedding_job_zip.key
  source_code_hash = data.archive_file.embedding_job.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.jobs[*].id
    security_group_ids = [aws_security_group.jobs.id]
  }

  environment {
    variables = merge(local.lambda_env, {
      S3VECTORS_BUCKET_NAME = aws_s3vectors_vector_bucket.main.vector_bucket_name
      S3VECTORS_INDEX_NAME  = aws_s3vectors_index.transcript_segments.index_name
    })
  }

  tags = { Name = "${local.name}-embedding-job" }
}

resource "aws_cloudwatch_log_group" "transcriber_job" {
  name              = "/aws/lambda/${aws_lambda_function.transcriber_job.function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "embedding_job" {
  name              = "/aws/lambda/${aws_lambda_function.embedding_job.function_name}"
  retention_in_days = 30
}
