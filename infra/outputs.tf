output "app_service_url" {
  description = "Public HTTPS URL analysts/clients hit -- App Runner's own default domain, the only internet-facing endpoint in the stack."
  value       = "https://${aws_apprunner_service.app_service.service_url}"
}

output "video_bucket_name" {
  value = aws_s3_bucket.videos.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master credentials (rotatable by RDS itself)."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "vector_bucket_name" {
  value = aws_s3vectors_vector_bucket.main.vector_bucket_name
}

output "vector_index_arn" {
  value = aws_s3vectors_index.transcript_segments.index_arn
}

output "ecr_repository_url" {
  description = "Push app-service's real image here, then flip app_service_image_repository_type to \"ECR\" and app_service_image_identifier to \"<this>:<tag>\"."
  value       = aws_ecr_repository.app_service.repository_url
}

output "lambda_function_names" {
  value = {
    transcriber_job = aws_lambda_function.transcriber_job.function_name
    embedding_job   = aws_lambda_function.embedding_job.function_name
  }
}

output "vpc_id" {
  value = aws_vpc.main.id
}
