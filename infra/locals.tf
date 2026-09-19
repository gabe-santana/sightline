locals {
  name = "${var.project_name}-${var.environment}"

  video_bucket_name = coalesce(
    var.video_bucket_name,
    "${local.name}-videos-${data.aws_caller_identity.current.account_id}"
  )

  # Tiered private subnets within the single VPC (see the "VPC topology"
  # decision in docs/architecture.md): app-service's VPC connector, the
  # three Lambda jobs, and the RDS data layer each get their
  # own subnets/AZs so Security Groups -- not network boundaries -- enforce
  # who can talk to whom.
  az_count = length(var.availability_zones)

  app_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  jobs_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  data_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, 20 + i)]
}

data "aws_caller_identity" "current" {}
