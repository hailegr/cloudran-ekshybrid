# Best Practices — Deferred Improvements

Identified during alpha-v0.2 e2e testing (2026-04-24).

## Security

### 1. BMC credentials in plain text in Git
`server-groups/<cluster>/<group>.yaml` contains `bmcUser` and `bmcPass` in plain text. These are committed to Git history permanently.
**Fix**: Use ExternalSecrets or SealedSecrets to reference credentials from AWS Secrets Manager. Server-group YAML should reference a secret name, not the actual password.

### 2. Root password in plain text in values
`generic-platform-definitions/tinkerbell/bare-metal/values.yaml` → `osProfiles.*.rootSetup.password` is plaintext.
**Fix**: Use a hashed password or reference a Secret.

### 3. ACK capability role has AdministratorAccess
`cdk/lib/mgmt-cluster-stack.ts` grants the ACK/kro role `AdministratorAccess`.
**Fix**: Scope to specific services (EKS, IAM, EC2, AMP, CloudWatch).

### 4. Unpinned image tags in action-registry
`generic-platform-definitions/tinkerbell/registry/deployment.yaml` uses `amazon/aws-cli:latest`, `quay.io/skopeo/stable:latest`, and `registry:2`. Mutable tags risk supply chain attacks.
**Fix**: Pin to specific versions. Add these to the mirror pipeline for air-gapped environments.

## ArgoCD / GitOps

### 5. All apps use `project: default`
No source/destination restrictions. A misconfigured Application could deploy anywhere.
**Fix**: Create scoped AppProjects per concern (tinkerbell, observability, infrastructure).

### 6. Duplicate `syncOptions` in action-registry Application
`charts/workload-apps/templates/apps.yaml` ~line 240 has `syncOptions` defined twice. Second silently overrides first.
**Fix**: Remove the duplicate block.

### 7. Triplicate `ignoreDifferences` jqPathExpression
The tinkerbell-stack Application lists `TINKERBELL_IPXE_HTTP_SCRIPT_EXTRA_KERNEL_ARGS` three times in `ignoreDifferences`.
**Fix**: Keep one.

### 8. endpoint-sync RBAC for argocd namespace is now unused
`generic-platform-definitions/tinkerbell/stack-bootstrap/rbac.yaml` still grants the endpoint-sync ServiceAccount access to ArgoCD Applications. This was needed for the old `registryAddress` patching approach, which was removed.
**Fix**: Remove the argocd namespace Role and RoleBinding.

### 9. No retry policy on ApplicationSet-generated apps
The bare-metal ApplicationSet doesn't set `syncPolicy.retry`. Transient errors (e.g., kro CRD not ready) won't auto-retry.
**Fix**: Add `syncPolicy.retry` with backoff.

## Kubernetes / Reliability

### 10. action-registry uses `emptyDir` for registry data
Pod restart loses all seeded images. Re-seeding from ECR takes time; provisioning workflows fail during this window.
**Fix**: Use a PVC, or add a readiness probe that verifies images are seeded.

### 11. No resource requests/limits on seed-images and ecr-login containers
Could be OOM-killed or starve other pods.
**Fix**: Add resource requests and limits.

### 12. ECR auth token expires after 12 hours
The `ecr-login` init container runs once. Token goes stale if the pod runs longer than 12 hours.
**Fix**: Refresh token via a sidecar loop or CronJob.

### 13. No PodDisruptionBudgets
Tinkerbell stack, action-registry, and image-server have no PDBs. Node drains could evict all replicas simultaneously.
**Fix**: Add PDBs with `minAvailable: 1`.

## Helm / Chart Structure

### 14. `apps.yaml` is a 500+ line monolith
`charts/workload-apps/templates/apps.yaml` contains every Application, ConfigMap, RBAC, and Service in one file.
**Fix**: Split into separate files per concern.

### 15. Hardcoded AWS account ID and region in action-registry
`registry/deployment.yaml` has `AWS_REGION: us-west-1` and `AWS_ACCOUNT_ID: "833542146025"` hardcoded.
**Fix**: Source from a ConfigMap or Helm values.

### 16. No automated template validation
No CI validates `helm template`, kustomize builds, or YAML schema before merge.
**Fix**: Add pre-commit hooks or CI pipeline.

### 17. No ArgoCD notifications
No alerting on sync failures, degraded health, or provisioning errors.
**Fix**: Configure ArgoCD Notifications with SNS or Slack.

### 18. Image versions scattered across files
Tinkerbell chart version, tink-agent version, action image versions, and tool versions are spread across `apps.yaml`, `values.yaml`, `mirror-images.yaml`, and `endpoint-sync-job.yaml`.
**Fix**: Centralize in a single version manifest or Helm global values.
