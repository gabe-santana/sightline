# Ready to receive app-service's real image in the next phase. Until then,
# app_service_image_repository_type = "ECR_PUBLIC" points App Runner at
# AWS's public bootstrap image instead (see apprunner.tf).
resource "aws_ecr_repository" "app_service" {
  name                 = "${local.name}-app-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # same reasoning as aws_s3_bucket.videos in s3.tf

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${local.name}-app-service" }
}

resource "aws_ecr_lifecycle_policy" "app_service" {
  repository = aws_ecr_repository.app_service.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
