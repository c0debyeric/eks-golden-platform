# GitHub Actions → AWS OIDC Setup

How CI in this repo authenticates to AWS with **no stored access keys** — short-lived credentials
minted per-run via OpenID Connect federation.

## How it works

```
GitHub Actions job (on: push to main)
   │  mints an OIDC token; claims include:
   │     sub = repo:c0debyeric/eks-golden-platform:ref:refs/heads/main
   │     aud = sts.amazonaws.com
   ▼
aws-actions/configure-aws-credentials  →  sts:AssumeRoleWithWebIdentity
   ▼
AWS validates:
   1. token signed by the trusted GitHub OIDC provider   (account-wide IAM OIDC provider)
   2. sub + aud match the role's trust policy EXACTLY     (StringEquals, no wildcards)
   ▼
returns creds valid ~1h  →  terraform plan runs  →  creds expire, nothing stored
```

## The two AWS resources

| Resource | Scope | This account |
|----------|-------|--------------|
| IAM OIDC provider (`token.actions.githubusercontent.com`) | one per account, shared | **already existed** — referenced via data source, not recreated |
| IAM role (`gha-eks-golden-platform`) | one per repo | created by `terraform/bootstrap/` |

Role ARN: `arn:aws:iam::123456789012:role/gha-eks-golden-platform`

## Bootstrap (run ONCE, locally, with admin creds)

The role that lets CI run Terraform can't be created by that same CI (chicken-and-egg), so apply
the bootstrap module yourself:

```bash
cd terraform/bootstrap
terraform init
terraform apply          # creates the IAM role scoped to this repo's main branch

# Wire the output into GitHub (already done, but this is how):
gh variable set AWS_ROLE_ARN \
  --body "$(terraform output -raw role_arn)" \
  --repo c0debyeric/eks-golden-platform
```

Bootstrap state is intentionally **local** — it's a tiny, rarely-changed config, and the S3 backend
the main module uses may not exist on first bootstrap.

## The workflow

`.github/workflows/terraform.yml`:
- `permissions: id-token: write` — REQUIRED, or GitHub won't mint the OIDC token.
- `lint` job (fmt + validate) runs on PRs too — needs no AWS creds.
- `plan` job runs only on `main` (matching the trust scope) and assumes the role via
  `vars.AWS_ROLE_ARN`.

## Security notes

- **Trust is `StringEquals`, not `StringLike`.** The `sub` claim is matched exactly to
  `repo:c0debyeric/eks-golden-platform:ref:refs/heads/main`. A wildcard here would let other repos
  or branches assume the role — the #1 GitHub-OIDC mistake.
- **`aud` is pinned to `sts.amazonaws.com`** so a token minted for another service can't be replayed.
- **1-hour max session.** CI jobs are short; raise `max_session_duration` only if a plan/apply needs longer.
- **AdministratorAccess** is attached because the main module provisions VPC+EKS+IAM+KMS+SQS (broad
  by nature) in a sandbox account. For a shared/prod account, replace it with a scoped policy — see below.

## Tightening for a shared/prod account

Swap the `AdministratorAccess` attachment in `terraform/bootstrap/oidc.tf` for a customer-managed
policy limited to the services the main module touches (EC2/VPC, EKS, IAM role/policy for cluster +
Karpenter + Pod Identity, KMS, SQS, S3+DynamoDB for state). Add a GitHub **Environment** with a
required-reviewer gate and change `allowed_ref` to `environment:production` so `apply` needs manual
approval.

## Extending to other repos

Copy `terraform/bootstrap/` (or add a second role resource), change `github_repo`, apply, set that
repo's `AWS_ROLE_ARN`. One OIDC provider serves every repo in the account; each repo gets its own
scoped role.
