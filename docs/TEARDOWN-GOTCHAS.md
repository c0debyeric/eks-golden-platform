# Teardown & State-Lock Gotchas

Hard-won operational lessons from tearing down this platform in the `sandbox`
account (`123456789012`). If `terraform destroy` hangs or errors, check here first.

## 1. Killing `terraform apply` orphans BOTH a cluster and the state lock

Killing the apply process (`kill`/Ctrl-C hard) does **not**:

- **Stop server-side EKS creation.** The control plane keeps provisioning in AWS
  after the local process dies. You end up with a cluster that exists in AWS but
  is **not in Terraform state** (`terraform state list` won't show
  `aws_eks_cluster.this`). AWS also **rejects `delete-cluster` while status is
  `CREATING`** — you must `aws eks wait cluster-active` first, then delete.

- **Release the S3 state lock.** Because the backend uses `use_lockfile = true`,
  the lock is an **S3 object** (`<key>.tflock`), not a DynamoDB row. A killed
  process leaves it behind. The next `destroy`/`apply` fails with:

  ```
  Error: Error acquiring the state lock
  StatusCode: 412 ... PreconditionFailed
  ```

  **Fix:** confirm no real terraform is running (VS Code `terraform-ls` /
  `ms-terraform-lsp` language servers DON'T count — they never hold the lock),
  then force-unlock with the ID from the error message:

  ```bash
  terraform force-unlock -force <LOCK_ID>
  ```

  Verify live processes first:
  ```bash
  pgrep -af terraform | grep -v -e pgrep -e terraform-ls -e terraform-lsp
  ```

## 2. VPC won't delete: `DependencyViolation` from a Firewall Manager SG

After the cluster + subnets + ENIs are all gone, `destroy` can still fail:

```
Error: deleting EC2 VPC (vpc-...): DependencyViolation:
The vpc '...' has dependencies and cannot be deleted.
```

Terraform destroyed everything **it** created, but an org-level **AWS Firewall
Manager (FMS)** policy auto-injects a security group into every VPC in the
account:

```
FMManagedSecurityGroup<uuid>-sg-<id>-vpc-<vpcid>
```

This SG is **untracked** by our Terraform, so `destroy` can't remove it, and it
blocks VPC deletion. Diagnose and clear:

```bash
VPC=vpc-xxxx; P="--profile sandbox --region us-east-1"
# Confirm what's left (expect no ENIs, no subnets, no LBs):
aws ec2 describe-network-interfaces $P --filters Name=vpc-id,Values=$VPC --query 'NetworkInterfaces[].NetworkInterfaceId'
aws ec2 describe-subnets           $P --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId'
# Find the FMS-managed SG:
aws ec2 describe-security-groups   $P --filters Name=vpc-id,Values=$VPC \
  --query 'SecurityGroups[?GroupName!=`default`].{ID:GroupId,Name:GroupName}'
# Delete it (works if the FMS policy isn't actively re-protecting it):
aws ec2 delete-security-group      $P --group-id <SG_ID>
# Then re-run destroy — VPC deletes in ~0s:
terraform destroy -auto-approve
```

Note: `aws fms list-policies` requires being the FMS **admin account** — in a
member/sandbox account you'll get `AccessDeniedException`. You don't need FMS
admin to delete the orphaned SG; the account-local `delete-security-group` is
enough as long as the policy isn't actively reconciling.

## 3. Post-teardown verification (prove billing stopped)

```bash
terraform state list                                    # expect empty
aws eks list-clusters --profile sandbox --region us-east-1 --query clusters
aws ec2 describe-vpcs --profile sandbox --region us-east-1 \
  --filters Name=tag:Project,Values=eks-golden-platform --query 'Vpcs[].VpcId'
aws ec2 describe-nat-gateways --profile sandbox --region us-east-1 \
  --filter Name=tag:Project,Values=eks-golden-platform \
  --query 'NatGateways[?State!=`deleted`].NatGatewayId'   # NAT = the pricey one
```

All four should return empty before you consider the account clean.
