resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.data[*].id

  tags = { Name = "${local.name}-db" }
}

# manage_master_user_password = true means RDS creates and rotates the
# master password in Secrets Manager itself -- no password ever passes
# through Terraform state or a .tfvars file.
resource "aws_db_instance" "postgres" {
  identifier     = "${local.name}-postgres"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username

  manage_master_user_password = true

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_allocated_storage_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period = 7
  # Both flipped for a dev environment's convenience (fast, clean
  # `terraform destroy`). Set deletion_protection = true and
  # skip_final_snapshot = false before this holds real data.
  deletion_protection = false
  skip_final_snapshot = true

  tags = { Name = "${local.name}-postgres" }
}
