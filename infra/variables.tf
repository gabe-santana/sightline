variable "aws_region" {
  description = "AWS region to deploy into. us-east-1 has the broadest Bedrock model availability."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name, used in resource naming/tags."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Short project name used as a resource-naming prefix."
  type        = string
  default     = "sightline"
}

variable "vpc_cidr" {
  description = "CIDR block for the single Sightline VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Two AZs to spread subnets/RDS across."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "video_bucket_name" {
  description = "Globally-unique S3 bucket name for uploaded videos and derived artifacts. Defaults to a name derived from project/environment/account if left null."
  type        = string
  default     = null
}

variable "db_name" {
  description = "Postgres database name."
  type        = string
  default     = "sightline"
}

variable "db_username" {
  description = "Postgres master username."
  type        = string
  default     = "sightline"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.micro is the smallest Graviton class -- cheap, fine for dev."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version. Confirmed available in us-east-1 at the time of writing."
  type        = string
  default     = "16.15"
}

variable "db_allocated_storage_gb" {
  description = "RDS allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Whether RDS is Multi-AZ. false keeps dev cost down; set true before this is a production database."
  type        = bool
  default     = false
}

variable "embedding_dimension" {
  description = "Output vector dimension of whichever Bedrock embedding model embedding-job calls. 1024 matches Amazon Titan Text Embeddings V2's default (also supports 256/512) -- change this and the S3 Vectors index together if a different model is chosen."
  type        = number
  default     = 1024
}

variable "embedding_distance_metric" {
  description = "Similarity metric for the S3 Vectors index. \"cosine\" is standard for normalized text embeddings (e.g. Titan)."
  type        = string
  default     = "cosine"

  validation {
    condition     = contains(["cosine", "euclidean"], var.embedding_distance_metric)
    error_message = "embedding_distance_metric must be \"cosine\" or \"euclidean\" (the only values S3 Vectors supports)."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the three Lambda jobs."
  type        = string
  default     = "python3.13"
}

variable "lambda_architecture" {
  description = "Lambda instruction set architecture."
  type        = string
  default     = "arm64"
}

variable "app_service_cpu" {
  description = "App Runner vCPU allocation (as accepted by the App Runner API, e.g. \"1 vCPU\")."
  type        = string
  default     = "1 vCPU"
}

variable "app_service_memory" {
  description = "App Runner memory allocation (e.g. \"2 GB\")."
  type        = string
  default     = "2 GB"
}

variable "app_service_image_repository_type" {
  description = "\"ECR_PUBLIC\" for the bootstrap placeholder image, or \"ECR\" once app-service's real image has been pushed to the repository this stack creates."
  type        = string
  default     = "ECR_PUBLIC"

  validation {
    condition     = contains(["ECR_PUBLIC", "ECR"], var.app_service_image_repository_type)
    error_message = "app_service_image_repository_type must be \"ECR_PUBLIC\" or \"ECR\"."
  }
}

variable "app_service_image_identifier" {
  description = "Container image App Runner deploys. Defaults to AWS's public bootstrap sample image so App Runner's public endpoint can be stood up and tested before app-service's real image exists. Point this at <ecr_repository_url>:<tag> once it does."
  type        = string
  default     = "public.ecr.aws/aws-containers/hello-app-runner:latest"
}

variable "app_service_port" {
  description = "Port the deployed image listens on. The bootstrap public.ecr.aws/aws-containers/hello-app-runner image listens on 8000 (verified by inspecting the image directly). src/app-service's real Dockerfile listens on 8080 -- set this to \"8080\" in the same terraform.tfvars change that switches app_service_image_identifier over to it."
  type        = string
  default     = "8000"
}
