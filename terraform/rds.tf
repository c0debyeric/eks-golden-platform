# Demonstration RDS PostgreSQL topology in the isolated database subnet tier (network.tf):
#
#   Multi-AZ PRIMARY (multi_az=true)  -> synchronous standby in a 2nd AZ (HA/failover, NOT readable)
#   READ REPLICA 1  -> pinned us-east-1b (async, readable, own endpoint)
#   READ REPLICA 2  -> pinned us-east-1c (async, readable, own endpoint)
#
# WHY both mechanisms: the Multi-AZ standby solves HIGH AVAILABILITY (auto-failover), the read
# replicas solve READ SCALING + cross-AZ read resilience. They are DISTINCT — a standby is never
# readable. Together they are the production golden pattern. See docs/NETWORK-ARCHITECTURE.md.
#
# Entire stack is gated on var.create_rds (default false) so the base platform stays cheap.

locals {
  # The two AZs to pin read replicas into. The primary+standby consume 2 of the 3 DB subnets;
  # placing replicas in us-east-1b and us-east-1c spreads read capacity across AZs.
  rds_replica_azs = var.create_rds ? ["us-east-1b", "us-east-1c"] : []

  # Derive the parameter-group family + major from the engine version so they can never drift
  # out of sync with rds_engine_version (e.g. "18.4" -> "postgres18", major "18").
  rds_major        = split(".", var.rds_engine_version)[0]
  rds_param_family = "postgres${local.rds_major}"
}

########################################
# RDS security group — least-privilege data-plane boundary
########################################
# Only the EKS worker nodes' security group may reach PostgreSQL on 5432. This is the REAL
# enforcement boundary (the NAT-less database subnets are defense-in-depth on top of this).
# Scoped to the node SG, NOT the whole VPC CIDR — a tighter grant than "anything in the VPC".
resource "aws_security_group" "rds" {
  count = var.create_rds ? 1 : 0

  name        = "${var.name}-rds"
  description = "PostgreSQL access for ${var.name} - EKS nodes only"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  count = var.create_rds ? 1 : 0

  security_group_id            = aws_security_group.rds[0].id
  description                  = "PostgreSQL from EKS worker nodes"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id # pods/nodes reach the DB
}

# No egress rule needed for RDS itself; the isolated subnet route table already blocks
# internet egress. (RDS doesn't initiate outbound connections in this design.)

########################################
# Master credentials — self-managed secret (NOT RDS-managed)
########################################
# WHY not manage_master_user_password: RDS does NOT support creating read replicas from a
# Postgres source whose credentials are RDS-managed in Secrets Manager (AWS docs; SQL Server
# is the only exception). Since we need replicas, we manage the master password ourselves:
# generate it, store it in a Secrets Manager secret we own, and pass it to the primary via
# password_wo (write-only — never persisted in plan/state). Apps read the secret via ESO,
# the same pattern as Grafana.
resource "random_password" "rds_master" {
  count = var.create_rds ? 1 : 0

  length  = 32
  special = false # avoid shell/URL-escaping headaches in connection strings
}

resource "aws_secretsmanager_secret" "rds_master" {
  count = var.create_rds ? 1 : 0

  name        = "${var.name}/rds-master"
  description = "Master credentials for the ${var.name} RDS primary"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  count = var.create_rds ? 1 : 0

  secret_id = aws_secretsmanager_secret.rds_master[0].id
  # Standard RDS-style secret shape so ESO/apps can parse it uniformly.
  secret_string = jsonencode({
    username = "app_admin"
    password = random_password.rds_master[0].result
    engine   = "postgres"
    port     = 5432
    dbname   = "appdb"
    host     = module.rds_primary[0].db_instance_address
  })
}

########################################
# Primary — Multi-AZ, self-managed master password (replica-compatible)
########################################
module "rds_primary" {
  source  = "terraform-aws-modules/rds/aws"
  version = ">= 7.0"

  count = var.create_rds ? 1 : 0

  identifier = "${var.name}-primary"

  engine               = "postgres"
  engine_version       = var.rds_engine_version
  family               = local.rds_param_family # DB parameter group family (derived from version)
  major_engine_version = local.rds_major        # (ignored for postgres option group — none created)
  instance_class       = var.rds_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100 # storage autoscaling ceiling
  storage_encrypted     = true

  db_name  = "appdb"
  username = "app_admin"
  port     = 5432

  # HIGH AVAILABILITY: synchronous standby in a second AZ, auto-promoted on primary failure.
  multi_az = true

  # Self-managed master password (see the random_password + secret above). password_wo is
  # write-only: Terraform sends it to RDS but never stores it in state. NOT manage_master_user_password,
  # because that would block read-replica creation for Postgres (AWS limitation).
  manage_master_user_password = false
  password_wo                 = random_password.rds_master[0].result
  password_wo_version         = 1

  # Place into the ISOLATED database subnet tier (created by the VPC module, network.tf).
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  # Backups are REQUIRED to create read replicas (retention must be >= 1).
  backup_retention_period = 7
  backup_window           = "03:00-06:00"
  maintenance_window      = "Mon:00:00-Mon:03:00"

  # Observability: ship Postgres logs to CloudWatch + enable Performance Insights.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true
  create_monitoring_role          = true
  monitoring_interval             = 60
  monitoring_role_name            = "${var.name}-rds-monitoring"

  # Postgres has no option group; let the module skip it.
  create_db_option_group = false

  # Portfolio/teardown posture: no deletion protection, no final snapshot. FLIP BOTH for prod
  # (deletion_protection = true, skip_final_snapshot = false) so a DB can't be destroyed casually.
  deletion_protection = false
  skip_final_snapshot = true

  tags = var.tags
}

########################################
# Read replicas — one per remaining AZ, readable, own endpoints
########################################
# READ SCALING: async replicas of the primary. Each has its own connection endpoint; point
# read-heavy queries here. replicate_source_db wires the replication link; a replica must NOT
# manage its own master password (it inherits the source's) and cannot be Multi-AZ here.
#
# APPLY NOTE: creating a replica briefly puts the SOURCE into a non-"available" state, so when
# Terraform creates both replicas in parallel (default), the second can fail with
# "InvalidDBInstanceState: DB instance is not in the available state". This is transient — just
# re-run `terraform apply` (idempotent; the first replica is already in state), or apply with
# `-parallelism=1` on a fresh build to force the replicas to serialize.
module "rds_replica" {
  source  = "terraform-aws-modules/rds/aws"
  version = ">= 7.0"

  count = var.create_rds ? 2 : 0

  identifier = "${var.name}-replica-${count.index + 1}"

  # Source database (same-region: use the identifier; cross-region would use the ARN).
  replicate_source_db = module.rds_primary[0].db_instance_identifier

  # Pin each replica to a distinct AZ for cross-AZ read distribution/resilience.
  availability_zone = local.rds_replica_azs[count.index]

  engine         = "postgres"
  engine_version = var.rds_engine_version
  family         = local.rds_param_family
  instance_class = var.rds_instance_class

  # A replica inherits storage from its source; it does NOT create its own subnet group
  # (it lives in the source's subnet group) and does NOT manage a master password.
  # max_allocated_storage=0 disables independent storage autoscaling on the replica — it
  # follows the source's storage, and RDS reports 0 here, so setting it keeps plan idempotent.
  create_db_subnet_group      = false
  manage_master_user_password = false
  multi_az                    = false
  max_allocated_storage       = 0

  vpc_security_group_ids = [aws_security_group.rds[0].id]

  # Replicas don't need their own backups (backup_retention_period = 0 disables them).
  backup_retention_period = 0
  maintenance_window      = "Tue:00:00-Tue:03:00"

  enabled_cloudwatch_logs_exports = ["postgresql"]
  performance_insights_enabled    = true

  create_db_option_group    = false
  create_db_parameter_group = false # replicas reuse the source's parameter group family

  deletion_protection = false
  skip_final_snapshot = true

  tags = var.tags
}
