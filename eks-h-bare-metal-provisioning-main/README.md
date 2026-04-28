# EKS Hybrid Nodes — Bare Metal Provisioning with Tinkerbell & GitOps

Automated bare metal provisioning for [EKS Hybrid Nodes](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-overview.html) using Tinkerbell, ArgoCD, kro, and GitOps.

A management EKS cluster runs ArgoCD, ACK, and kro (all as EKS Capabilities). Through `values.yaml` and `server-groups/` files, it creates workload EKS clusters, deploys the Tinkerbell stack, and provisions bare metal servers as EKS hybrid nodes — all via Git commits.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Management EKS Cluster (created by CDK)                    │
│  ┌───────────┐  ┌─────────────┐  ┌────────────────────────┐ │
│  │  ArgoCD   │  │ ACK (EKS,   │  │ Helm umbrella chart    │ │
│  │  root app │──│ IAM, EC2)   │  │ + kro WorkloadCluster  │ │
│  └───────────┘  └─────────────┘  └────────────────────────┘ │
│       │              │                                      │
│       │    kro creates workload clusters, IAM roles, SGs    │
└───────┼──────────────┼──────────────────────────────────────┘
        │              │
        ▼              ▼
┌─────────────────────────────────────────────────────────────┐
│  Workload EKS Cluster (per cluster in values.yaml)          │
│  ┌───────────┐  ┌────────────┐  ┌─────────────────────────┐ │
│  │  ArgoCD   │  │ Tinkerbell │  │ Cilium, cert-manager,   │ │
│  │   (own)   │  │ Stack      │  │ AWS LBC, kro            │ │
│  └───────────┘  └────────────┘  └─────────────────────────┘ │
│       │              │                                      │
│       │    kro BareMetalServer CRD manages per-server:      │
│       │    BMC Secret, Machine, Hardware, Workflow          │
└───────┼──────────────┼──────────────────────────────────────┘
        │              │
        ▼              ▼
┌─────────────────────────────────────────────────────────────┐
│  Bare Metal Servers                                         │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Ubuntu + nodeadm → joins EKS as hybrid node via SSM  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- An existing VPC with at least 2 subnets
- An IAM Identity Center instance configured with users/groups for ArgoCD SSO
- AWS account with permissions to create EKS clusters, IAM roles, security groups, NLBs
- Bare metal servers with **Redfish-compatible BMC** and network connectivity to the EKS VPC
- CLI tools: `helm`, `kubectl`, `aws-cdk`

## Quick Start

```bash
# 1. Create the management cluster
cd cdk
cp config.example.yaml config.yaml   # edit with your values
npm install && cdk deploy

# 2. Configure the Helm chart
cd ..
cp values.example.yaml values.yaml
# Fill in values from CDK stack outputs

# 3. Add workload clusters to values.yaml and create server group files
mkdir -p server-groups/my-workload-cluster
# Create server-groups/my-workload-cluster/site-group-1.yaml
# (see server-groups/example.yaml for format)

# 4. Bootstrap ArgoCD (run the BootstrapCommand from CDK outputs)
aws eks update-kubeconfig --name <cluster> --region <region>
helm template <cluster> charts/mgmt-bootstrap/ -f values.yaml | kubectl apply -f -

# 5. Push to the CodeCommit repo created by CDK
git remote set-url origin <CodeCommitRepoURL from CDK outputs>
git add -A && git commit -m "Initial site configuration" && git push
```

ArgoCD takes over from here — it creates workload EKS clusters, deploys Tinkerbell, and provisions bare metal servers as hybrid nodes.

## Configuration

- `values.yaml` — cluster-level config (AWS, IAM, workload cluster names, networking)
- `server-groups/<cluster>/<group>.yaml` — server definitions (source of truth for bare metal inventory)

## Day-2 Operations

**Add a workload cluster:**
1. Add an entry under `workloadClusters` in `values.yaml` with `serverGroups` list
2. Create `server-groups/<cluster>/<group>.yaml` files
3. `git add -A && git commit -m "Add cluster" && git push`

**Add servers** — add entries to the appropriate `server-groups/<cluster>/<group>.yaml`, commit and push.

**Re-provision a server** — delete its Workflow; kro will recreate it automatically:
```bash
kubectl delete workflow provision-<server-name> -n tinkerbell
```

**Decommission a cluster** — remove from `workloadClusters` in `values.yaml`, delete its `server-groups/<cluster>/` directory, commit and push. If the WorkloadCluster CR gets stuck in `Deleting` state (kro's finalizer waits for resources on the now-deleted cluster), remove the finalizer:
```bash
kubectl patch workloadcluster <cluster-name> -n default --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

## Observability

Each workload cluster is automatically provisioned with:

- **Amazon Managed Service for Prometheus (AMP)** workspace — created by kro via ACK
- **EKS control plane logging** — all 5 log types (api, audit, authenticator, controllerManager, scheduler) sent to CloudWatch
- **ADOT Collector** — scrapes metrics from telegraf (bare metal node metrics), cAdvisor (container metrics), kubelet (node metrics), and kube-apiserver, then remote-writes to the AMP workspace
- **Telegraf** — DaemonSet on hybrid nodes collecting CPU, memory, disk, network, and ethtool metrics, exposed via Prometheus endpoint (`:9273`)

Metrics are auto-discovered via a headless Kubernetes Service — as hybrid nodes join or leave, ADOT automatically starts or stops scraping them.

- **Grafana Operator** (optional) — if `grafana.endpoint` is configured in `values.yaml`, automatically registers AMP workspaces as data sources in Amazon Managed Grafana and provisions dashboards (Workload Cluster Overview, Tinkerbell Stack, EKS Cluster Status, Node Distribution, Infrastructure Overview, Provisioning Status). The rest of the observability stack works without Grafana.

## Documentation

- [USER-GUIDE.md](USER-GUIDE.md) — detailed deployment walkthrough, component reference, troubleshooting
- [cdk/README.md](cdk/README.md) — CDK stack reference (setup, config, teardown)
- [image-builder/README.md](image-builder/README.md) — OS image build pipeline, ownership model, security controls
