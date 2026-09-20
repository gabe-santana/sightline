# Single VPC, three tiers of private subnets (app / jobs / data), no
# Internet Gateway and no NAT Gateway anywhere. Every dependency the app
# and jobs have -- S3, Transcribe, Bedrock, Secrets Manager, S3 Vectors,
# RDS -- is reachable either via a VPC endpoint (PrivateLink) or directly
# within this one VPC, so there is nothing that needs general internet
# egress. That keeps the whole compute layer fully private with no NAT
# Gateway cost.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_subnet" "app" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.name}-app-${var.availability_zones[count.index]}", Tier = "app" }
}

resource "aws_subnet" "jobs" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.jobs_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.name}-jobs-${var.availability_zones[count.index]}", Tier = "jobs" }
}

resource "aws_subnet" "data" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.name}-data-${var.availability_zones[count.index]}", Tier = "data" }
}

# One shared route table: every subnet is private with no default route.
# The only "route" traffic needs is to the S3 gateway endpoint below,
# which attaches itself to whichever route tables it's given.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "app" {
  count          = local.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "jobs" {
  count          = local.az_count
  subnet_id      = aws_subnet.jobs[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "data" {
  count          = local.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- VPC endpoints: the reason no NAT Gateway is needed -------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.name}-s3" }
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type = "Interface"
  # Interface endpoints allow at most one subnet per AZ, so this can't list
  # both the jobs and app subnets (they overlap on AZ). One ENI per AZ,
  # placed in the data subnets, is reachable from every tier via ordinary
  # intra-VPC routing -- the "endpoints" Security Group's ingress rules
  # (not subnet placement) are what actually gate who can reach it.
  subnet_ids          = aws_subnet.data[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-bedrock-runtime" }
}

resource "aws_vpc_endpoint" "transcribe" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.transcribe"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.jobs[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-transcribe" }
}

# transcriber-job's own code calls events:PutEvents directly (to publish
# transcript_ready -- see handler.py's publish_transcript_ready) from
# inside its vpc_config'd ENI in the jobs subnet, which has no NAT/IGW.
# Without this endpoint that call has no path out and would fail with a
# connection timeout in production.
resource "aws_vpc_endpoint" "events" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.events"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.jobs[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-events" }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.data[*].id # see the comment on the bedrock_runtime endpoint above
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-secretsmanager" }
}

# embedding-job (Lambda) and app-service (query agent) both read/write the
# S3 Vectors index -- see s3vectors.tf for why S3 Vectors replaced OpenSearch
# as the semantic-search store.
resource "aws_vpc_endpoint" "s3vectors" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.s3vectors"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.data[*].id # see the comment on the bedrock_runtime endpoint above
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-s3vectors" }
}
