# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows semantic intent (pre-release `alpha` tags).

## [beta-v0.1] — 2026-04-24

### Added

- **Observability stack** — each workload cluster is automatically provisioned with:
  - Amazon Managed Service for Prometheus (AMP) workspace via ACK
  - EKS control plane logging (all 5 log types to CloudWatch)
  - ADOT Collector scraping telegraf, cAdvisor, kubelet, and kube-apiserver metrics, remote-writing to AMP
  - Grafana Operator for automated data source registration and dashboard provisioning
  - Cluster label on all metrics for multi-cluster dashboarding
- **ECR image mirror pipeline** (`image-builder/mirror-images.yaml`) — CodeBuild job copies public container images to private ECR for air-gapped provisioning, with multi-architecture and custom `disk-tools` image support
- **ECR auth for action-registry** — aws-cli init container obtains ECR token via IMDS, shared with skopeo sidecar via `REGISTRY_AUTH_FILE`
- **Dynamic action-registry address** — workflow templates resolve the registry IP at render time via Helm `lookup` on the `tinkerbell-endpoints` ConfigMap, eliminating hardcoded IPs
- **`seedImages` / `actionImages` separation** — `seedImages` (full ECR URIs, in top-level `values.yaml` per workload cluster) feed the action-registry; `actionImages` (short names, in bare-metal chart values) are used in workflow templates
- **Cross-region/cross-account workload clusters** — per-cluster AWS overrides and CodeConnection support
- **Cluster decommissioning procedure** documented in USER-GUIDE §8
- **Action Image Pipeline documentation** in USER-GUIDE §9 — end-to-end flow, config file locations, how to add new images, which ArgoCD apps to sync
- **`SECRETS.md`** — secret management options and tradeoffs

### Changed

- **Chart structure** — split single Helm umbrella chart into 4 separate charts (`mgmt-bootstrap`, `mgmt-workload-clusters`, `workload-apps`, `workload-bootstrap`); `values.yaml` moved to repository root
- **Action-registry** — replaced `docker:dind` (privileged) with skopeo + registry:2 (unprivileged); seed container now fails with `exit 1` if any image copy fails instead of silently continuing
- **OS image build** — `apt-get upgrade` runs before module installation to prevent kernel/modules-extra version mismatch; kernel version detected post-upgrade; Ubuntu cloud image pinned to dated release (`noble/20260323/`) instead of floating `current/`; output filename includes image source tag and build timestamp
- **Image server** — syncs S3 every 5 minutes instead of once at startup
- **Endpoint resolution** — consolidated into a single Job (was multiple)
- **Tinkerbell stack** — added redundancy (multi-replica)
- **ADOT Collector** — updated to v0.47.0; added `health_check` extension
- **ACK resources** — deletion policy set to `RETAIN` on security groups and launch templates
- **All container images pinned** — removed `:latest` tags from short-lived Jobs

### Fixed

- **No network after boot** — kernel 6.8.0-110 installed by `linux-tools-generic` metapackage but `linux-modules-extra` only installed for 6.8.0-106; fixed by upgrading guest packages first, then detecting and pinning to the post-upgrade kernel
- **Action-registry 401 from ECR** — crane had no ECR credentials; replaced with skopeo + IMDS-based ECR auth via init container
- **tink-agent pulling from Docker Hub** — `actionImages` contained short names without registry prefix; fixed by Helm `lookup` to dynamically prepend `<registryIP>:5000/`
- **`seedImages` not read by ConfigMap template** — were in the wrong values file (bare-metal chart instead of top-level `values.yaml` under `workloadClusters`)
- **Default BMC credentials removed** from RGD and chart templates
- **AMP workspace ID** — added `readyWhen` to kro RGD to ensure `workspaceID` is available before ADOT config references it
- **Multi-source Helm** — switched to `$values` ref instead of relative `../../values.yaml` path
- **Hardcoded AWS account/region in action-registry** — replaced with ConfigMap-sourced env vars (`awsRegion`, `awsAccountId` from `action-registry-config`)
- **Duplicate `syncOptions` in action-registry ArgoCD Application** — removed duplicate key that silently dropped the first block
- **Image-server HA** — converted from Deployment + shared PVC to StatefulSet with `volumeClaimTemplates` (per-replica EBS) and required pod anti-affinity for guaranteed node spread
- **inventory-rgd `name_servers` type mismatch** — split comma-separated string to list

### Removed

- Redundant and outdated files cleaned up
- `docker:dind` privileged container from action-registry
- Test data (`values.yaml`, `server-groups/alpha-v02-test-worker/`) excluded from release

### Documentation

- USER-GUIDE rewritten: fixed `chart/values.yaml` → `values.yaml` (8 occurrences), `chart/` → `charts/`, repo structure updated to reflect 4-chart layout
- USER-GUIDE repo structure updated: removed stale references to deleted files (`SETUP.md`, `os-image-pipeline-section.md`, `setup-mgmt-cluster.sh`), added mirror pipeline and observability files
- `image-builder/README.md` expanded with full OS image pipeline documentation (ownership model, architecture, security controls, lifecycle operations) — previously in deleted `os-image-pipeline-section.md`
- `cdk/README.md` — added Teardown section (capability deletion, `cdk destroy`, retained resource cleanup)
- `KNOWN-ISSUES.md` — added `AdministratorAccess` IAM policy as issue #8; updated header for broader scope
- Known issue "Action Registry Uses docker:dind with Privileged Mode" marked as resolved
- All 7 issues from `REVIEW-tmp.md` verified as resolved

---

## [alpha-v0.2] — 2026-04-20

52 files changed, +4499 / −457 vs `alpha-v0.1`.

### Added

- **CDK stacks** (`cdk/`)
  - `mgmt-cluster-stack.ts` — EKS management cluster, IAM capability roles (ArgoCD, ACK), CodeCommit repo, access entries
  - `image-builder-stack.ts` — CodeBuild project + S3 bucket for golden OS image pipeline
  - `config.example.yaml`, `package.json`, `tsconfig.json`, entrypoint `bin/mgmt-cluster.ts`, stack README
- **kro `ResourceGraphDefinition`s** replacing the Kustomize + Helm PoC
  - `generic-platform-definitions/infrastructure/workload-cluster-kro/rgd.yaml` — `WorkloadCluster` CRD (creates EKS cluster, IAM roles, SG, addons, capabilities, nodegroup, access entries)
  - `generic-platform-definitions/tinkerbell/bare-metal-kro/inventory-rgd.yaml` — `BareMetalServerInventory` CRD (BMC Secret, Machine, Hardware)
  - `generic-platform-definitions/tinkerbell/bare-metal-kro/provision-rgd.yaml` — `BareMetalServerProvision` CRD (SSM activation Job, Workflow)
  - `generic-platform-definitions/tinkerbell/bare-metal-kro/deprovision-rgd.yaml` — `BareMetalDeprovision` CRD (drain → disk wipe Workflow → UEFI NVRAM clear → BMC power-off)
  - Supporting scripts: `scripts/create-activation.sh`, `scripts/drain-node.sh`
- **Tinkerbell Helm chart** (`generic-platform-definitions/tinkerbell/bare-metal/`)
  - Templates: `bare-metal-server.yaml`, `deprovision.yaml`, `resolve-endpoints-job.yaml`, `template.yaml`, `wipe-template.yaml`, `Chart.yaml`, `values.yaml`
- **Platform values** — `generic-platform-definitions/platform-values/values.yaml` (machine / OS / network / tuning profiles for CNF hybrid-bundle consumers)
- **Image builder pipeline** (`image-builder/`)
  - `build.sh`, `buildspec.yml`, `images.yaml`, `load-config.py`, `README.md`
- **Docs**
  - `SETUP.md` — shell script alternative for management cluster bootstrap
  - `cdk/README.md` — CDK stack reference
  - `os-image-pipeline-section.md` — OS image pipeline deep-dive
  - Known-issue section in `USER-GUIDE.md` including the ArgoCD EKS Capability health-check limitation
- **Scripts**
  - `scripts/setup-mgmt-cluster.sh` — idempotent eksctl-based management cluster bootstrap
  - `scripts/provision-timing.sh` — end-to-end provisioning timeline from Workflow labels
  - `scripts/mgmt-cluster-config.example.yaml`
- **Chart templates**
  - `chart/templates/workload-admin-access.yaml` — admin access entries on workload clusters
- **Repo hygiene**
  - Root `.gitignore` (excludes `node_modules/`, `cdk.out/`, `chart/values.yaml`, `server-groups/*/`, etc.)
  - `server-groups/example.yaml` — single canonical example server-group file

### Changed

- **Split** `BareMetalServer` into **Inventory + Provision** RGDs so Hardware (`allowWorkflow: true`) is always created before the Workflow attempts to attach — eliminates the long-standing Workflow race condition.
- **Boot flow**: switched from kexec to Tinkerbell `customboot` — ISO served via Redfish virtual media, BMC power-cycle after workflow actions complete. Uses correct Redfish device name `Cd`.
- **Hardware `userData` patching**: SSM activation Job now patches the Hardware's `userData` from a ConfigMap so Tootles cloud-init receives the up-to-date join script each re-provision.
- **Re-provisioning**: `provisionHash` field on `BareMetalServerProvision` triggers re-provision via GitOps — bump the value, ArgoCD reconciles, kro recreates the Workflow.
- **Workflow `readyWhen`**: corrected to `SUCCESS` (from the incorrect `STATE_SUCCESS`).
- **Root ArgoCD Application** renamed `workload-app-of-apps` → `eks-h-bare-metal`.
- **Tinkerbell / image-server NLBs**: cross-zone load balancing enabled.
- **Hybrid Nodes security group** attached to cluster; **IMDS hop limit** set to 2 on mgmt nodegroup.
- **README.md** and **USER-GUIDE.md** rewritten to reflect the kro-based architecture, provisioning/deprovisioning flows, per-cluster network and pod-CIDR overrides, and current day-2 procedures.
- **chart/templates/** — `workload-cluster.yaml`, `workload-apps.yaml`, `workload-bootstrap.yaml`, `bootstrap.yaml`, `values.example.yaml` reworked around the new kro CRDs; removed obsolete `workload-capabilities-access.yaml`, `workload-iam-networking.yaml`, `_helpers.tpl` (folded into RGDs).

### Removed

- `server-groups/workload-cluster-1/site-group-1.yaml` — per-cluster server group files are now user-owned (gitignored); only `server-groups/example.yaml` ships.

### Fixed

- Race condition where the Workflow could be created before Hardware, leaving it permanently stuck.
- `resolve-endpoints` race against NLB provisioning on first deploy (retries and ordering).
- Cross-zone traffic blackholing on multi-AZ NLBs.
- Cluster not attached to `hybrid-nodes-sg` at creation time.
- ArgoCD re-sync race on `allowWorkflow` toggling during re-provisioning.
- SSM activation Job now verifies the SHA256 checksum of the downloaded `kubectl` binary (supply-chain hardening).

### Known Issues

See [`USER-GUIDE.md §2`](USER-GUIDE.md#2-known-issues).

- BMC credentials stored in plain text in Git (SealedSecrets recommended)
- `AmazonSSMFullAccess` on the SSM activation Job role (scope-down pending)
- Action registry runs Docker-in-Docker with `privileged: true` (migration to skopeo/crane pending)
- Custom resource health checks not supported on ArgoCD EKS Capability — `WorkloadCluster` CRs show as `Unknown` in the mgmt ArgoCD UI (cosmetic)
- Per-cluster `hybridPodCIDR` override is not honored by Cilium — use the global value only until the Cilium Application is updated
- Several short-lived Jobs use unpinned `:latest` tags — planned replacement with CSE-vended pinned images

### Security Notes

- Repository history prior to `alpha-v0.2` was rewritten to remove real AWS account IDs, VPC IDs, IAM user ARNs, SSO instance/user/group IDs, and BMC network/credential details.
- The previous `poc-test` working history remains available locally on `backup-2026-04-20-pre-cleanup` but is not published.

---

## [alpha-v0.1] — 2026-04-10

Customer-facing baseline corresponding to `gitlab/main` (commit `aca21e3`).

### Included

- Initial Helm umbrella chart and per-workload-cluster ApplicationSet
- Tinkerbell stack (Smee, Tink, HookOS) deployed via Helm + Kustomize
- Mgmt cluster bootstrap via CodeCommit + ArgoCD EKS Capability + ACK
- Dynamic NLB endpoint resolution (PostSync hook)
- Initial README + USER-GUIDE
