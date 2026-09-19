# app-service's outbound path into the VPC (to reach RDS and the interface
# endpoints for Bedrock/Secrets Manager/S3 Vectors).
resource "aws_apprunner_vpc_connector" "app_service" {
  vpc_connector_name = "${local.name}-app-service"
  subnets            = aws_subnet.app[*].id
  security_groups    = [aws_security_group.app.id]
}

resource "aws_apprunner_service" "app_service" {
  service_name = "${local.name}-app-service"

  source_configuration {
    auto_deployments_enabled = false

    image_repository {
      image_identifier      = var.app_service_image_identifier
      image_repository_type = var.app_service_image_repository_type

      image_configuration {
        port = var.app_service_port
        # Same DB/bucket vars the Lambda jobs get (see local.lambda_env in
        # lambda.tf), plus the S3 Vectors bucket/index app-service's query
        # route reads from -- same pairing embedding_job's environment
        # uses. The bootstrap placeholder image ignores these; they take
        # effect once app_service_image_repository_type = "ECR" points at
        # the real image (see infra/README.md).
        runtime_environment_variables = merge(local.lambda_env, {
          S3VECTORS_BUCKET_NAME = aws_s3vectors_vector_bucket.main.vector_bucket_name
          S3VECTORS_INDEX_NAME  = aws_s3vectors_index.transcript_segments.index_name
        })
      }
    }

    dynamic "authentication_configuration" {
      for_each = var.app_service_image_repository_type == "ECR" ? [1] : []
      content {
        access_role_arn = aws_iam_role.apprunner_ecr_access.arn
      }
    }
  }

  instance_configuration {
    cpu               = var.app_service_cpu
    memory            = var.app_service_memory
    instance_role_arn = aws_iam_role.app_service_instance.arn
  }

  network_configuration {
    # Egress still goes through the VPC connector -- app-service reaches
    # RDS, Bedrock, Secrets Manager, and S3 Vectors privately either way.
    egress_configuration {
      egress_type       = "VPC"
      vpc_connector_arn = aws_apprunner_vpc_connector.app_service.arn
    }

    # Publicly accessible on App Runner's own default HTTPS domain --
    # App Runner already load-balances and autoscales behind that domain,
    # so there's no separate load balancer or gateway in front of it.
    # This was previously private-only behind API Gateway + a VPC Ingress
    # Connection; that layer was removed because an ALB can't be put in
    # front of App Runner's private ingress (it can't rewrite the Host
    # header App Runner's shared PrivateLink endpoint requires), and
    # API Gateway's own private-integration workaround wasn't worth
    # keeping once a plain load balancer was preferred instead. See
    # docs/architecture.md for the current ingress story.
    ingress_configuration {
      is_publicly_accessible = true
    }
  }

  tags = { Name = "${local.name}-app-service" }
}
