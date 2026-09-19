# Security-group-based segmentation is what actually enforces "who can
# talk to whom" in this single-VPC design -- see the "VPC topology"
# decision recorded in docs/architecture.md.

resource "aws_security_group" "jobs" {
  name_prefix = "${local.name}-jobs-"
  description = "transcriber-job / embedding-job Lambda ENIs"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-jobs" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "app" {
  name_prefix = "${local.name}-app-"
  description = "app-service App Runner VPC connector ENIs"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds-"
  description = "Amazon RDS (Postgres)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-rds" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "endpoints" {
  name_prefix = "${local.name}-endpoints-"
  description = "Interface VPC endpoints (Bedrock, Transcribe, Secrets Manager, S3 Vectors)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-endpoints" }

  lifecycle { create_before_destroy = true }
}

# --- Egress: jobs and app only reach exactly what they need ---------------

resource "aws_vpc_security_group_egress_rule" "jobs_to_rds" {
  security_group_id            = aws_security_group.jobs.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "jobs_to_endpoints" {
  security_group_id            = aws_security_group.jobs.id
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "jobs_to_s3" {
  security_group_id = aws_security_group.jobs.id
  # S3 is a Gateway endpoint (routed, not an ENI/SG target), so its egress
  # rule is prefix-list-based rather than security-group-based.
  prefix_list_id = aws_vpc_endpoint.s3.prefix_list_id
  from_port      = 443
  to_port        = 443
  ip_protocol    = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_to_rds" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_to_endpoints" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# DNS: interface endpoints' private DNS names (and RDS's own
# endpoint hostnames) need to resolve against the VPC's built-in resolver.
# AWS documents this resolver as reachable regardless of Security Group
# rules (the same exemption as the instance metadata service), but these
# cost nothing and remove any doubt rather than relying on that.
resource "aws_vpc_security_group_egress_rule" "jobs_dns_tcp" {
  security_group_id = aws_security_group.jobs.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "jobs_dns_udp" {
  security_group_id = aws_security_group.jobs.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "app_dns_tcp" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_dns_udp" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

# --- Ingress: data layer and endpoints only accept from their callers -----

resource "aws_vpc_security_group_ingress_rule" "rds_from_jobs" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.jobs.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_jobs" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.jobs.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_app" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

