# Known Issues and Deferred Fixes

Issues discovered during alpha-v0.2 and beta-v0.1 testing. Tracked here for follow-up.

## 1. CDK stack names fail when `clusterName` contains a dot

**Discovered:** 2026-04-20 during `test/alpha-v0.2-e2e`.

**Severity:** Medium — blocks any customer whose `clusterName` contains a `.` (e.g. version-tagged names like `alpha-v0.2-test-mgmt`).

**Error:**
```
«StackNameInvalidFormat» Stack name must match the regular expression:
/^[A-Za-z][A-Za-z0-9-]*$/, got 'alpha-v0.2-test-mgmt-mgmt'
```

**Root cause:** `cdk/bin/mgmt-cluster.ts` concatenates `${config.clusterName}-mgmt` / `${config.clusterName}-image-builder` directly as the stack name without sanitizing. The EKS CfnCluster resource accepts dots in its `Name`, but the CloudFormation/CDK stack name regex does not.

**Workaround used for e2e test:** set `clusterName: alpha-v02-test-mgmt` (no dot).

**Proposed fix (2 lines):**
```typescript
// cdk/bin/mgmt-cluster.ts
const stackPrefix = config.clusterName.replace(/[^A-Za-z0-9-]/g, "-");
const mgmt = new MgmtClusterStack(app, `${stackPrefix}-mgmt`, { ... });
new ImageBuilderStack(app, `${stackPrefix}-image-builder`, { ... });
```
This keeps the EKS cluster name as configured (with dots if desired), only sanitizing the CDK-level stack identifier.

**Validation:** After fix, `clusterName: alpha-v0.2-test-mgmt` should produce stack names `alpha-v0-2-test-mgmt-mgmt` and `alpha-v0-2-test-mgmt-image-builder`.

---

## 2. Image-builder CodeBuild fails when CodeCommit repo is empty

**Discovered:** 2026-04-20 during `test/alpha-v0.2-e2e`, first `codebuild start-build` attempt.

**Severity:** Medium — breaks the quick-start flow if the user follows README's numbered steps literally.

**Error:**
```
DOWNLOAD_SOURCE FAILED: remote repository is empty for primary source
```

**Root cause:** `cdk/lib/image-builder-stack.ts` configures the CodeBuild project to pull source from the mgmt cluster's CodeCommit repo (`image-builder/buildspec.yml` as buildspec). When `cdk deploy image-builder` runs immediately after `cdk deploy mgmt`, the CodeCommit repo is empty — no source, no buildspec — so CodeBuild fails instantly.

**Implicit ordering requirement:** mgmt deploy → `git push` repo content to CodeCommit → image-builder deploy → `codebuild start-build`.

**Documentation gap:** README Quick Start steps 1-5 do not make this ordering explicit. Steps 1-2 (`cdk deploy` + edit values.yaml) happen before step 5 (`git push`), but CodeBuild can't be triggered until after the push. USER-GUIDE Phase 1 also doesn't flag this.

**Proposed fixes (pick one):**
- **(a)** Document the ordering in README and USER-GUIDE Phase 1: "Push the repo to CodeCommit before triggering CodeBuild."
- **(b)** Split image-builder deploy out of `cdk/bin/mgmt-cluster.ts` so it isn't deployed in the same `cdk deploy *` pass, with a note to run it after `git push`.
- **(c)** Have CodeBuild take the source from GitHub (public) and use a stable `BUILDSPEC_OVERRIDE` env var, decoupling it from the customer's CodeCommit content.

Recommend (a) + (c) for a future release.

---

## 3. Image-server init container doesn't re-sync when OS image lands in S3 after pod start

**Discovered:** 2026-04-20 during `test/alpha-v0.2-e2e`, first `provision: true` attempt.

**Severity:** Medium — blocks the happy-path quick-start if the image build completes after the image-server pod is already running.

**Status:** Fix in progress.

**Symptom:** Provisioning Workflow action `extract-os-archive` fails with a 404 from the image-server NLB URL, e.g. `http://<imageServerIP>:80/ubuntu24-eks-1.35-amd64.tar.gz`. The OS archive is present in S3 but not on the image-server pod's filesystem.

**Root cause:** `generic-platform-definitions/tinkerbell/image-server/deployment.yaml` uses a single-shot init container (`sync-images`) that runs `aws s3 sync` once at pod start. If the S3 bucket is empty at that moment, the init container exits `0` (success, nothing to copy), the pod enters `Running`, and nginx serves an empty directory. When the image lands in S3 later (e.g. after CodeBuild completes), nothing triggers a re-sync. Kubernetes has no mechanism to restart a pod when upstream object storage content changes.

**Sequence that reproduces it:**
1. `cdk deploy` mgmt + image-builder stacks
2. `git push` chart/values.yaml with `imageBucket` set
3. ArgoCD reconciles → deploys image-server with empty S3 bucket → init runs, syncs nothing, pod `Running` with empty content
4. Trigger CodeBuild → image lands in S3
5. Trigger provisioning → Workflow hits 404 on OS archive URL

**Workaround:** After CodeBuild completes, force the image-server pod to restart:
```bash
kubectl -n tinkerbell delete pod -l app=image-server
```
The new pod's init container re-runs `aws s3 sync` and pulls the image.

**Proposed fix options (pick one):**
- **(a)** Make the init container fail if no matching files are found in the bucket (`aws s3 ls` check before sync, exit non-zero if empty). CrashLoopBackOff forces k8s to retry until the image lands.
- **(b)** Replace the init container with a sidecar that polls S3 every N minutes and triggers a nginx reload on change (e.g. rclone bisync + inotify, or a tiny Go controller).
- **(c)** Use S3 event notification → SNS → Lambda → `patch deployment` to force a rollout when a new image object lands.
- **(d)** Document the ordering requirement: run the image build and wait for completion BEFORE applying bootstrap / pushing to CodeCommit.



---

## 4. Cross-account ECR pull requires repository policy

**Discovered:** 2026-04-23 during cross-region/cross-account refactoring.

**Severity:** Medium — blocks cross-account deployments that use the ECR image mirror.

**Context:** The `ImageMirrorStack` creates ECR repositories in the management account. The action-registry init container on workload clusters pulls from these repos. In same-account deployments, the nodegroup role's `AmazonEC2ContainerRegistryReadOnly` policy is sufficient.

**Problem:** In cross-account deployments (workload cluster in a different AWS account), the workload account's nodegroup role cannot pull from the management account's ECR repositories by default. ECR does not allow cross-account pulls without an explicit repository policy.

**Required for cross-account:**
1. Add an ECR repository policy on each repo in the management account allowing `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, and `ecr:BatchCheckLayerAvailability` from the workload account's nodegroup role, **or**
2. Run the `ImageMirrorStack` in each workload account so ECR repos are local, **or**
3. Use ECR cross-account replication rules to replicate repos to workload accounts.

**Workaround:** For now, deploy the mirror stack in each account separately. Update `mirror-images.yaml` and run `cdk deploy` + `codebuild start-build` in each account.

**Proposed fix:** Add an optional `allowedAccountIds` list to `mirror-images.yaml` or CDK config. The `ImageMirrorStack` would add a repository policy granting pull access to those accounts.

---

## 5. Capability deletePropagationPolicy only supports RETAIN

**Discovered:** 2026-04-23 during deletion testing of `alpha-v02-test-delete` cluster.

**Severity:** Low — cosmetic / operational inconvenience during cluster decommissioning.

**Error:**
```
InvalidParameterException: Invalid delete propagation policy
```

**Root cause:** The EKS Capability API only supports `RETAIN` as the `deletePropagationPolicy` value. `DELETE` is not yet implemented. See [API docs](https://docs.aws.amazon.com/eks/latest/APIReference/API_Capability.html).

**Impact:** When a WorkloadCluster CR is deleted, kro deletes the Capability CRs, but EKS retains the ArgoCD/ACK/kro installations on the workload cluster. Resources deployed by those capabilities (Tinkerbell apps, Cilium, etc.) are not automatically cleaned up. The EKS cluster itself is deleted by ACK, which orphans the retained capability resources.

**Workaround:** Before deleting a WorkloadCluster CR, manually delete the capabilities from the EKS console or CLI:
```bash
aws eks delete-capability --cluster-name <cluster> --capability-name <cluster>-argocd --region <region>
aws eks delete-capability --cluster-name <cluster> --capability-name <cluster>-ack --region <region>
aws eks delete-capability --cluster-name <cluster> --capability-name <cluster>-kro --region <region>
```
Or accept that the retained resources are destroyed when the EKS cluster is deleted.

**Future fix:** Switch to `DELETE` when the EKS API adds support for it.

---

## 6. Cluster decommissioning requires two-step process to avoid orphaned AWS resources

**Discovered:** 2026-04-23 during deletion ordering analysis.

**Severity:** High — orphaned NLBs and security groups incur ongoing costs and block VPC deletion.

**Problem:** The WorkloadCluster kro RGD manages IAM roles, security groups, the EKS cluster, and capabilities. But resources created by controllers running ON the workload cluster (NLBs from AWS LBC, security groups from LBC) are invisible to the mgmt cluster's deletion DAG. Deleting the WorkloadCluster CR directly orphans these resources.

**Orphaned resources if deleted without cleanup:**
- NLBs created by AWS Load Balancer Controller (Tinkerbell, image-server)
- Security groups created by AWS LBC for NLB target groups
- EKS Capability installations (ArgoCD, ACK, kro) — retained due to `RETAIN` policy

**Correct decommissioning procedure:**

```bash
# Step 1: Delete the bootstrap app on the mgmt cluster.
# This removes the workload cluster's root ArgoCD app, which cascades:
# workload ArgoCD prunes all apps → LBC deletes NLBs → Tinkerbell cleaned up.
kubectl delete application <cluster>-argocd-bootstrap -n argocd

# Step 2: Wait for NLBs to be fully deleted (~2-5 min).
# Check that no load balancers remain for this cluster:
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName,'<cluster>')].[LoadBalancerName,State.Code]" \
  --output table

# Step 3: Delete the WorkloadCluster CR.
# kro deletes: capabilities, addons, nodegroup, cluster, IAM roles, SG.
kubectl delete workloadcluster <cluster> -n default

# Step 4: If the WorkloadCluster CR gets stuck in Deleting (kro finalizer),
# remove the finalizer:
kubectl patch workloadcluster <cluster> -n default --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'

# Step 5: Remove the cluster from values.yaml workloadClusters and push.
# This prevents ArgoCD from recreating the WorkloadCluster CR.
```

**Why not automate this in kro?** kro deletes resources in reverse DAG order but does not wait for external side effects (NLB deletion by LBC). The EKS Capability API only supports `deletePropagationPolicy: RETAIN`, so capabilities cannot trigger cleanup of their managed resources. A future EKS API update supporting `DELETE` propagation would allow full automation.

**Alternative (quick but leaves orphans):** Delete the WorkloadCluster CR directly and manually clean up orphaned NLBs and security groups afterward:
```bash
# Find and delete orphaned NLBs
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName,'<cluster>')].[LoadBalancerArn]" \
  --output text | xargs -I{} aws elbv2 delete-load-balancer --load-balancer-arn {} --region <region>
```

---

## 7. Tinkerbell stack is single-instance (no HA)

**Severity:** Medium — provisioning is unavailable during pod rescheduling (~2-5 min).

**Current state:** Tinkerbell v0.22.1 deploys all components (tink-server, tink-controller, smee, tootles, rufio) in a single pod. The controllers (tink-controller, rufio) are not safe to run as multiple replicas — they could create duplicate BMC Jobs and cause conflicting provisioning operations.

**HA mitigations in place:**
- Kubernetes self-healing: if the node fails, the pod is rescheduled to another node
- Resource requests (500m CPU, 512Mi memory) ensure scheduling on a healthy node
- NLB health checks detect pod failure and re-route traffic when the new pod is ready
- Image-server and action-registry run 2 replicas with pod anti-affinity (spread across nodes) — the provisioning data path has redundancy even if one node fails

**Impact of Tinkerbell pod failure:**
- In-progress workflows are interrupted but resume when the pod restarts (Tinkerbell reconciles from Kubernetes state)
- New provisioning requests queue until the pod is healthy
- Already-provisioned bare metal nodes are unaffected (they run independently)

**What would be needed for true HA:**
1. Upstream Tinkerbell: split the single Deployment into separate Deployments per component
2. Add leader election to tink-controller and rufio
3. Scale stateless components (tink-server, smee, tootles) independently

**References:**
- [Tinkerbell HA discussion](https://github.com/tinkerbell/tinkerbell/issues/307)

---

## 8. ACK/kro capability role uses AdministratorAccess

**Discovered:** 2026-04-26 during beta-v0.1 release review.

**Severity:** High — overly broad IAM permissions on the management and workload clusters.

**Current state:** The CDK stack (`cdk/lib/mgmt-cluster-stack.ts`) creates a single IAM role for the ACK capability and attaches `arn:aws:iam::aws:policy/AdministratorAccess`. The kro capability reuses this same role. This means both ACK controllers and kro on every cluster have full AWS account admin access.

**Impact:** If an ACK or kro controller is compromised, the attacker gains unrestricted access to the entire AWS account. This violates the principle of least privilege.

**Why it exists:** During alpha development, scoping the exact permissions for ACK controllers managing EKS clusters, IAM roles, EC2 security groups, AMP workspaces, and S3 buckets was deferred in favor of rapid iteration. The permission surface is large because ACK creates and manages many different AWS resource types.

**Proposed fix:** Replace `AdministratorAccess` with a scoped policy covering only the services ACK actually manages:
- `eks:*` — cluster, nodegroup, addon, capability, access entry management
- `iam:*` (or scoped to `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PassRole`, etc.) — IAM roles for workload clusters
- `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:DeleteSecurityGroup`, `ec2:CreateLaunchTemplate`, `ec2:DeleteLaunchTemplate`, `ec2:Describe*` — security groups and launch templates
- `aps:*` — AMP workspace management
- `elasticloadbalancing:*` — NLB management (via AWS LBC)
- `sts:TagSession` — required by ACK
- `s3:GetObject`, `s3:ListBucket` — image bucket read access for Pod Identity

Additionally, kro should have its own role (or no AWS role at all, since it only manages Kubernetes resources).

**Workaround:** Customers deploying to production should replace the `AdministratorAccess` policy attachment in `cdk/lib/mgmt-cluster-stack.ts` with a scoped policy before running `cdk deploy`. The exact permissions depend on which ACK controllers and AWS resources are in use.

---

## 9. Workload cluster decommissioning orphans NLBs and Grafana resources

**Discovered:** 2026-04-27 during beta-v0.1 e2e testing.

**Severity:** High — orphaned NLBs incur ongoing costs and block VPC deletion.

**Current state:** The WorkloadCluster RGD creates a single `bootstrapApp` (ArgoCD Application) that deploys all workload apps (Tinkerbell, LBC, Grafana, etc.). On deletion, kro deletes `bootstrapApp` and immediately proceeds to delete the EKS cluster. The workload cluster's LBC and Grafana Operator are killed before they can clean up NLBs and AMG resources.

**Orphaned resources:**
- NLBs created by AWS Load Balancer Controller (Tinkerbell stack, image-server, action-registry)
- Security groups created by LBC for NLB target groups
- Grafana data sources and dashboards registered in Amazon Managed Grafana

**Current workaround:** Manual cleanup after decommissioning (documented in USER-GUIDE §8).

**Proposed fix — split bootstrap into two ArgoCD Applications in the RGD:**

```
WorkloadCluster RGD (kro)
│
├── infrastructureBootstrap (ArgoCD Application)
│   └── Creates: EKS cluster, IAM roles, SG, capabilities, nodegroup
│
└── workloadBootstrap (ArgoCD Application)
    └── dependsOn: infrastructureBootstrap
    └── Creates: Cilium, Tinkerbell, LBC, ADOT, Grafana, bare-metal servers
```

On deletion, kro's reverse DAG would:
1. Delete `workloadBootstrap` first (leaf node)
2. ArgoCD foreground cascade prunes all workload apps → LBC deletes NLBs → Grafana Operator cleans up AMG
3. kro waits for `workloadBootstrap` to be fully deleted
4. Then deletes `infrastructureBootstrap` → capabilities, cluster, IAM, SG

This ensures all workload-level resources are cleaned up while the cluster and its controllers are still running. The ArgoCD Application deletion with foreground cascade blocks until all managed resources are gone, giving LBC and Grafana Operator time to complete cleanup.

**Requirements:**
- Split `charts/workload-bootstrap` into two charts (infrastructure + workload)
- Add `dependsOn` relationship in the RGD between the two bootstrap apps
- Verify ArgoCD foreground cascade deletion behavior with EKS Capability
