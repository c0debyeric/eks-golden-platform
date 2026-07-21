# Network layer: VPC with a three-tier subnet layout (public / private / database) per AZ,
# plus a free S3 gateway endpoint. Subnet CIDRs are derived from the VPC CIDR so the whole
# address plan moves with a single var change. See docs/NETWORK-ARCHITECTURE.md.

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Subnet CIDRs derived from the VPC CIDR, three tiers per AZ:
  #   private  /20  (10.20.0.0 .. 10.20.47.x)  — EKS nodes + pods (large: pods burn IPs fast)
  #   public   /24  (10.20.48.x .. 10.20.50.x) — ALBs + NAT gateways
  #   database /24  (10.20.64.x .. 10.20.66.x) — RDS/data tier, ISOLATED (no NAT/IGW route)
  # The +48 / +64 offsets keep the /24 tiers clear of the /20 private block and each other.
  private_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 48)]
  database_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 64)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 6.0"

  name = "erics-${var.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Dedicated data tier for RDS/ElastiCache. The module builds an RDS DB subnet group
  # (create_database_subnet_group) spanning these subnets across all AZs — RDS requires
  # a subnet group covering >=2 AZs even for a single-AZ instance. Crucially, these
  # subnets get their OWN route table with NO NAT/IGW route (create_database_nat_gateway_route
  # left false), so a compromised database host physically cannot egress to the internet.
  # Defense-in-depth: app/data segmentation at the routing layer, on top of security groups.
  database_subnets                   = local.database_subnets
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway # cost lever (see variables.tf)
  enable_dns_hostnames = true

  # Subnet tags REQUIRED for controllers to discover where to place load balancers and nodes.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1" # public ELBs land here
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"      # internal ELBs
    "karpenter.sh/discovery"          = var.name # Karpenter EC2NodeClass subnet discovery
  }

  tags = var.tags
}

resource "aws_vpc_endpoint" "s3" {
  # Free gateway endpoint: Loki chunk PUT/GET to S3 bypasses NAT data-processing charges.
  vpc_id          = module.vpc.vpc_id
  service_name    = "com.amazonaws.${var.region}.s3"
  route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
  tags            = var.tags
}
