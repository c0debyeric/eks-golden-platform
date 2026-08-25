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

## 4. Telemetry S3 buckets are RETAINED on teardown (by design)

The Loki (`eks-golden-loki-chunks`, `eks-golden-loki-ruler`) and Tempo
(`eks-golden-tempo-traces`) buckets deliberately have **no `force_destroy`**, so
`terraform destroy` will **fail to delete them while they hold objects**:

```
Error: deleting S3 Bucket (eks-golden-tempo-traces): BucketNotEmpty:
The bucket you tried to delete is not empty
```

This is intentional — logs and traces are meant to **survive `make down`/`make up`**
(that's the whole point of S3 backing). `make down` tears down the cluster/VPC/NAT
(the expensive parts) and leaves these near-$0 buckets behind so telemetry history
persists across rebuilds.

If you want a **full** clean-up (permanently discard telemetry history), empty and
delete them explicitly AFTER `make down`:

```bash
P="--profile sandbox --region us-east-1"
for b in eks-golden-loki-chunks eks-golden-loki-ruler eks-golden-tempo-traces; do
  aws s3 rm "s3://$b" --recursive $P        # empty objects (+ versions if versioned)
  aws s3api delete-bucket --bucket "$b" $P  # then remove the bucket
done
```

Standing S3 storage cost for these is negligible (a few $/mo at portfolio log/trace
volume), so the default is to keep them.

---

## 5. Values that used to be pinned to ONE cluster instance (fixed — here's what to watch)

The repo's headline claim is a teardown/rebuild lifecycle: `make down` returns you to
~$0, `make up` rebuilds, and Argo CD restores the workload layer from Git. That claim
was quietly false. Two committed GitOps values were literals that are only correct for
a single build of the platform, and both would have been wrong on the first rebuild:

| file | was | why it breaks on rebuild |
|---|---|---|
| `gitops/bootstrap/karpenter.yaml` | `clusterEndpoint: https://<hash>...` | EKS mints a new API endpoint per cluster. Karpenter would launch nodes that cannot reach the API server to join, so the cluster comes up with **no workload capacity** — while Karpenter itself stays Running and Healthy, so nothing points at it. |
| `gitops/apps/alb-controller/values.yaml` | `vpcId: vpc-0c...` | `destroy` deletes the VPC; `apply` creates one with a new id. The controller CrashLoopBackOffs, and its admission webhook then rejects **every** Service/Ingress cluster-wide, stalling the whole app-of-apps sync behind it. |

Neither failure names the stale value, and the Karpenter one carried no warning
comment at all. Both are now resolved at RUNTIME instead of being committed:

- Karpenter uses `settings.eksControlPlane: true`, which discovers cluster details
  (endpoint included) via `eks:DescribeCluster`. The controller role granted by
  `module.karpenter` already carries that action, so no IAM change is needed.
- The ALB controller uses `vpcTags` instead of `vpcId` — the chart's documented
  alternative for the pods-cannot-reach-IMDS case that forced an explicit value here
  in the first place. Tags are ANDed and both are derived from Terraform variables
  (`erics-${var.name}-vpc` from `name`, and `Project` from `tags`), so they are stable
  across rebuilds in a way an id can never be.

**What still needs a human on rebuild:** nothing, for these two. But the tag values
above track `name` and `tags` in `terraform.tfvars`. If you rename the platform, update
`vpcTags` in `gitops/apps/alb-controller/values.yaml` to match, or the controller will
fail to resolve a VPC and take Service admission down with it.

Sanity check after any `make up`, before trusting the cluster:

```bash
# Karpenter resolved an endpoint and can launch nodes
kubectl -n kube-system logs deploy/karpenter | grep -i 'cluster.endpoint\|failed'
kubectl get nodeclaims          # should reach Ready, not sit Unknown

# The ALB controller resolved exactly one VPC (no CrashLoop, no webhook outage)
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl -n kube-system logs deploy/aws-load-balancer-controller | grep -i 'vpc\|failed to get'
```

Anything else that hardcodes a per-build identifier belongs in this table. Grep for one
before committing:

```bash
grep -rn 'vpc-[0-9a-f]\{8,\}\|\.gr7\..*\.eks\.amazonaws\.com' gitops/ charts/
```
