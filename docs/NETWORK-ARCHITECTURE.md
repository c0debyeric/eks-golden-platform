# Network Architecture

The VPC uses a **three-tier subnet layout per AZ**, derived deterministically from the
VPC CIDR (`terraform/main.tf` locals). Default is 3 AZs → 9 subnets.

```
VPC 10.20.0.0/16  (az_count=3)
│
├─ PUBLIC   /24 per AZ   10.20.48.0/24  .49  .50
│   route: 0.0.0.0/0 → Internet Gateway
│   holds: ALBs/NLBs (public), NAT gateways
│
├─ PRIVATE  /20 per AZ   10.20.0.0/20   .16  .32     ← large: pods burn IPs (VPC-CNI)
│   route: 0.0.0.0/0 → NAT gateway (per-AZ)
│   holds: EKS nodes + pods, internal ELBs
│
└─ DATABASE /24 per AZ   10.20.64.0/24  .65  .66
    route: LOCAL ONLY — no NAT, no IGW
    holds: RDS / ElastiCache (via the RDS DB subnet group)
```

## NAT gateways — one per AZ (production default)

`single_nat_gateway` defaults to **false** = one NAT gateway per AZ. This is the
recommended production posture:

- **AZ-fault isolation** — if one AZ's NAT fails, only that AZ's private egress is
  affected; the other AZs keep working. A single shared NAT is a single-AZ SPOF for
  ALL private egress in the VPC.
- **No cross-AZ NAT data hop** — each AZ's private subnets route through their own
  zonal NAT, avoiding cross-AZ data transfer charges on egress.

Cost: ~$97/mo (3× NAT hourly + data) vs. ~$32/mo for a single shared NAT. Set
`single_nat_gateway = true` in `terraform.tfvars` for the cheap demo posture.

The **S3 gateway endpoint** (`aws_vpc_endpoint.s3` in main.tf) is free and keeps
Loki→S3 chunk traffic off the metered NAT entirely.

## The database tier — why it exists (and why RDS does NOT require it)

**Common misconception:** "I need to add an RDS subnet before I can run a database."

**Reality:** RDS does not require a bespoke subnet tier. RDS requires a **DB Subnet
Group** — a logical list of ≥2 subnets across ≥2 AZs that RDS is allowed to place
instances in (mandatory even for a single-AZ instance). That group could simply be
the existing private subnets, and isolation could be enforced purely at the
**security-group** layer (RDS SG allows :5432 only from the node SG). That is a
valid, simpler design.

**Why we still added a dedicated `database_subnets` tier:** defense-in-depth, not
necessity. The data-tier subnets get their **own route table with no NAT/IGW route**
(`create_database_subnet_route_table = true`, and we do NOT set
`create_database_nat_gateway_route`). Result: a compromised database host **physically
cannot egress to the internet** — there is no route to exfiltrate over, independent of
security-group misconfiguration. App/data segmentation at the routing layer, layered on
top of SGs.

**What to avoid:** creating a *single* "RDS subnet." RDS mandates ≥2 AZs in the subnet
group, so a one-subnet tier fails immediately. If you build the tier, build it per-AZ
with its own NAT-less route table — otherwise it buys nothing over reusing the private
subnets.

## Using the database tier

The module creates the RDS subnet group automatically (named after the VPC). To attach
an RDS instance:

```hcl
resource "aws_db_instance" "app" {
  # ... engine, instance_class, etc.
  db_subnet_group_name   = module.vpc.database_subnet_group_name  # the isolated tier
  vpc_security_group_ids = [aws_security_group.rds.id]            # allow :5432 from node SG only
  publicly_accessible    = false
}
```

An in-cluster app reaches it via the RDS endpoint DNS; egress from pods to the DB stays
intra-VPC (private → database, both LOCAL routes). Credentials should flow through
External Secrets Operator → Secrets Manager (the pattern already wired for Grafana), not
static env vars.
