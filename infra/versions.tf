terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.60 for aws_s3vectors_* resource support (see s3vectors.tf).
      # Reviewed the v5->v6 upgrade guide against every resource type used
      # in this stack before bumping: only aws_db_instance, aws_opensearch_domain
      # (removed), and aws_s3_bucket have documented breaking changes, and
      # none apply to how this configuration uses them.
      version = "~> 6.65"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Local state for now -- see infra/README.md for how/when to move this to
  # an S3 + DynamoDB remote backend before more than one person applies this.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "sightline"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
