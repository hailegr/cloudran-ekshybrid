# EKS-H User Guide

> Zero-touch bare metal provisioning with EKS, ArgoCD, ACK, and Tinkerbell

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Known Issues](#2-known-issues)
3. [Prerequisites](#3-prerequisites)
4. [Deployment Guide](#4-deployment-guide)
5. [Adding a New Workload Cluster](#5-adding-a-new-workload-cluster)
6. [Adding Bare Metal Servers](#6-adding-bare-metal-servers)
7. [Re-provisioning a Server](#7-re-provisioning-a-server)
8. [Decommissioning a Workload Cluster](#8-decommissioning-a-workload-cluster)
9. [Component Reference](#9-component-reference)
10. [Observability](#10-observability)
11. [Safe Rollout Architecture (Future)](#11-safe-rollout-architecture-future)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture Overview

### Hub-and-Spoke Model

A manually created **management cluster** uses ArgoCD and ACK (both installed as EKS Capabilities) to create and manage **workload clusters**. Each workload cluster gets its own ArgoCD instance that manages the Tinkerbell bare metal provisioning stack and workload applications.

All site-specific configuration lives in a single `values.yaml` file at the repository root. Helm charts in `charts/` generate all Kubernetes resources — EKS clusters, IAM roles, security groups, ArgoCD Applications — from this one file.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AWS Region                                   │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Management Cluster                                          │   │
│  │                                                              │   │
│  │  ArgoCD (EKS Capability)     ACK (EKS Capability)            │   │
│  │    │                           │                             │   │
│  │    │ watches                   │ creates via AWS APIs        │   │
│  │    │ values.yaml               │                             │   │
│  │    │ (Helm umbrella)           ├─► EKS Cluster               │   │
│  │    │                           ├─► IAM Roles (per cluster)   │   │
│  │    ▼                           ├─► Nodegroup                 │   │
│  │  eks-h-bare-metal              ├─► Addons (VPC CNI, etc.)    │   │
│  │    │                           ├─► Capabilities (ArgoCD/ACK) │   │
│  │    │ deploys to                ├─► Access Entries            │   │
│  │    ▼                           └─► Pod Identity Assoc.       │   │
│  └──────────────────────────────────────────────────────────────┘   │
│           │                                                         │
│           ▼                                                         │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Workload Cluster (per entry in values.yaml)                 │   │
│  │                                                              │   │
│  │  ArgoCD (EKS Capability)                                     │   │
│  │    │ renders charts/ with renderOnly=apps-<cluster>          │   │
│  │    │                                                         │   │
│  │    ├─► cert-manager          (wave -10)                      │   │
│  │    ├─► cilium-cni            (wave -8)                       │   │
│  │    ├─► aws-lb-controller     (wave -8)                       │   │
│  │    ├─► tinkerbell-bare-metal-rbac (wave -6)                  │   │
│  │    ├─► tinkerbell-stack      (wave -5)                       │   │
│  │    ├─► tinkerbell-endpoint-sync (wave -4)                    │   │
│  │    ├─► image-server          (wave -3)                       │   │
│  │    ├─► tinkerbell-mtls       (wave 0)                        │   │
│  │    ├─► kro                  (wave 1)                         │   │
│  │    ├─► bare-metal-kro       (wave 2) ─ BareMetalServer RGD   │   │
│  │    └─► bare-metal           (wave 3) ─ per server group      │   │
│  │                                                              │   │
│  │  EC2 Nodes ◄──NLB──► Bare Metal Network                      │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              │ NLB (instance target, source IP      │
│                              │      preserved)                      │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Bare Metal Network (via Direct Connect / TGW / VPN)         │   │
│  │                                                              │   │
│  │  BMC Network (iDRAC/Redfish)                                 │   │
│  │  Data Network (node traffic)                                 │   │
│  │                                                              │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │   │
│  │  │ Bare Metal   │  │ Bare Metal   │  │ Bare Metal   │        │   │
│  │  │ (hybrid node)│  │ (hybrid node)│  │ (hybrid node)│        │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘        │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Bare Metal Provisioning Flow

When a server entry is added to `values.yaml` and pushed to `main`:

1. **PreSync Jobs** run before the bare-metal app syncs:
   - **SSM activation Job**: creates a single-use SSM activation (2h TTL), stores credentials in a Secret, writes Hardware userData (cloud-config with nodeadm join script) to a ConfigMap
   - **Endpoint resolver Job**: resolves NLB IPs for tinkerbell and image-server Services, writes them to a `tinkerbell-endpoints` ConfigMap
2. **Helm renders** Tinkerbell Templates and `BareMetalServer` kro instances (one per server)
3. **kro reconciles** each `BareMetalServer` instance in dependency order:
   - Waits for `tinkerbell-endpoints` ConfigMap (readyWhen: NLB IPs present)
   - Waits for `<server>-ssm` ConfigMap (readyWhen: userData present)
   - Creates BMC Secret → Machine → Hardware (with userData from ConfigMap, `allowWorkflow: true`)
   - Creates Workflow **last** — with real NLB IPs already baked in (no placeholders)
4. **Tinkerbell** picks up the Workflow:
   - Rufio mounts HookOS ISO on the server via Redfish Virtual Media
   - Rufio sets one-time boot to Virtual CD and power cycles the server
   - Server boots HookOS → tink-worker connects to Tink Server
   - Workflow actions execute: stream OS image → install drivers → configure network → write cloud-init config → kexec into Ubuntu
5. **Ubuntu boots** → cloud-init queries Tootles (Tinkerbell metadata service) → gets Hardware userData → writes nodeadm config → runs join script
6. **Server joins EKS** as a hybrid node via SSM + nodeadm

### How kro Eliminates the Workflow Race Condition

Previously, Workflows were created with placeholder URLs (`RESOLVE_AT_RUNTIME`) and patched by a PostSync Job after NLB IPs were resolved. Rufio could act on the Workflow before the patch, causing failed boot attempts.

With kro, the Workflow resource references the `tinkerbell-endpoints` ConfigMap via CEL expressions. kro's dependency DAG ensures the Workflow is **never created** until the ConfigMap exists and has valid IPs. By the time Rufio sees the Workflow, it already has correct URLs.

```
endpoints ConfigMap (externalRef, readyWhen: LB IPs present)
ssmData ConfigMap (externalRef, readyWhen: userData present)
    │
    ├── bmcSecret ──► machine ──► hardware (allowWorkflow: true,
    │                              safe because Workflow doesn't exist yet)
    │
    └── workflow (created LAST — real IPs from day 1)
```

### Bare Metal Resource Management with kro

Each server is managed as an atomic unit via a `BareMetalServer` custom resource (defined by a kro ResourceGraphDefinition). kro manages the full lifecycle: BMC Secret, Machine, Hardware, and Workflow.

- Each `BareMetalServer` is visible as a separate resource in ArgoCD with independent health status
- Tinkerbell Templates are shared across servers and rendered by Helm (not managed by kro)
- No `ignoreDifferences` or runtime patching needed — all values are resolved before resource creation

---

## 2. Known Issues

### HIGH: BMC Credentials in Plain Text in Git

Server group files (generated into `server-groups/`) contain BMC credentials (`bmcUser`/`bmcPass`) in plain text. The SSM activation Job also generates secrets that end up in Hardware userData.

**Fix**: Use SealedSecrets or an external secrets operator to encrypt BMC credentials at rest.

### HIGH: `AmazonSSMFullAccess` on SSM Job Role

The `ssm-job-role` has `AmazonSSMFullAccess` attached, which grants far more permissions than needed. The Job only needs `ssm:CreateActivation`, `ssm:DeleteActivation`, and `ssm:DescribeActivations`.

**Fix**: Replace with a scoped inline policy.

### LOW: Custom Resource Health Checks Not Supported on ArgoCD EKS Capability

The ArgoCD EKS Capability does not expose configuration for custom Lua health checks. As a result, the `WorkloadCluster` custom resource (and other kro-managed CRs) appear as `Unknown` in the management cluster's ArgoCD UI instead of `Healthy`. This is cosmetic only — the underlying resources reconcile correctly and their status is visible via `kubectl get workloadcluster`.

**Workaround**: None available while using the ArgoCD EKS Capability. If custom health checks are required, deploy ArgoCD yourself (outside the Capability) and add resource customizations via the ArgoCD ConfigMap.

### LOW: Unpinned `:latest` container images in action-registry

The action-registry deployment uses `:latest` tags on two init/sidecar containers (`amazon/aws-cli:latest`, `quay.io/skopeo/stable:latest`). This is a supply-chain risk and breaks reproducibility. All other Jobs and Deployments now use pinned versions.

**Affected file**:
- `generic-platform-definitions/tinkerbell/registry/deployment.yaml`

---

## 3. Prerequisites

### AWS IAM Identity Center (IDC)

ArgoCD on EKS uses IAM Identity Center for authentication and RBAC. You need an IDC instance configured before deploying.

**Setting up Identity Center for ArgoCD:**

1. **Enable IAM Identity Center** in your AWS account (if not already enabled):
   - Go to the [IAM Identity Center console](https://console.aws.amazon.com/singlesignon)
   - Choose your identity source (Identity Center directory, Active Directory, or external IdP)
   - Note the **IDC Instance ARN** (e.g., `arn:aws:sso:::instance/ssoins-abc123`) — you'll need this for `values.yaml`

2. **Create users or groups** that will administer ArgoCD:
   - In the Identity Center console, go to **Users** → **Add user**
   - Note each user's **User ID** (a UUID like `c488d4b8-4021-7016-be5e-9084fdd4db1e`) — you'll need these for the `argoCD.rbacRoleMappings` in `values.yaml`
   - You can find User IDs by selecting a user and looking at the **General information** section

3. **Map IDC users to ArgoCD roles** in `values.yaml`:
   ```yaml
   argoCD:
     idcInstanceARN: arn:aws:sso:::instance/ssoins-abc123
     idcRegion: us-east-1    # IDC is typically in us-east-1
     rbacRoleMappings:
       - role: ADMIN
         identities:
           - id: c488d4b8-4021-7016-be5e-9084fdd4db1e   # User ID from step 2
             type: SSO_USER
           # Add SSO_GROUP entries for group-based access:
           # - id: <group-id>
           #   type: SSO_GROUP
   ```

   When the ArgoCD EKS Capability is created on each workload cluster, it will be configured with these IDC settings automatically. Users can then log in to ArgoCD via SSO.

### AWS Resources

- An AWS account with sufficient IAM permissions
- A VPC with at least 2 subnets
- Network connectivity from the VPC to bare metal networks (Direct Connect, TGW, or VPN)

The CDK stack (`cdk/`) creates the EKS management cluster, CodeCommit repository, IAM roles, and all EKS capabilities (ArgoCD, ACK, kro) in a single `cdk deploy`. See [cdk/README.md](cdk/README.md) for configuration and outputs.

### CodeCommit Repository

Created automatically by the CDK stack. The clone URL is available in the `CodeCommitRepoURL` stack output — use it as `git.repoURL` in `values.yaml`. ArgoCD pulls from it via HTTPS using the ArgoCD capability role.

The ArgoCD capability role needs `AWSCodeCommitReadOnly` to pull from this repo (see below).

### EKS Management Cluster

Create an EKS cluster that will serve as the management hub. This cluster needs two EKS Capabilities: ArgoCD and ACK. Each capability requires an IAM role.

#### ArgoCD Capability Role

Create an IAM role for the ArgoCD capability. This role is assumed by the `capabilities.eks.amazonaws.com` service and needs:

- **Trust policy:**
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "capabilities.eks.amazonaws.com"
        },
        "Action": ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  }
  ```

- **Attached policies:**
  - `arn:aws:iam::aws:policy/AWSCodeCommitReadOnly` — allows ArgoCD to pull from CodeCommit repositories
  - `arn:aws:iam::aws:policy/AWSSecretsManagerClientReadOnlyAccess` — allows ArgoCD to read secrets (for Helm value decryption, if used)

```bash
aws iam create-role \
  --role-name AmazonEKSCapabilityArgoCDRole-<mgmt-cluster-name> \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "capabilities.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'

aws iam attach-role-policy \
  --role-name AmazonEKSCapabilityArgoCDRole-<mgmt-cluster-name> \
  --policy-arn arn:aws:iam::aws:policy/AWSCodeCommitReadOnly

aws iam attach-role-policy \
  --role-name AmazonEKSCapabilityArgoCDRole-<mgmt-cluster-name> \
  --policy-arn arn:aws:iam::aws:policy/AWSSecretsManagerClientReadOnlyAccess
```

This role ARN goes into `mgmtCluster.argoCDCapabilityRoleARN` in `values.yaml`. It is also used to:
- Install the ArgoCD capability on each workload cluster
- Grant `AmazonEKSClusterAdminPolicy` access on each workload cluster (so ArgoCD can deploy resources)

#### ACK Capability Role

Create an IAM role for the ACK capability. ACK controllers create AWS resources (EKS clusters, IAM roles, security groups) on your behalf, so this role needs broad permissions.

- **Trust policy:** same as ArgoCD — `capabilities.eks.amazonaws.com` service principal
- **Attached policies:** `arn:aws:iam::aws:policy/AdministratorAccess`

> **Note:** `AdministratorAccess` is used here for simplicity. In production, scope this down to the specific services ACK manages: `eks:*`, `iam:*`, `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup`, `ec2:AuthorizeSecurityGroup*`, `ec2:RevokeSecurityGroup*`, `ec2:DescribeSecurityGroups`, `ec2:CreateTags`, `ec2:DeleteTags`.

```bash
aws iam create-role \
  --role-name AmazonEKSCapabilityACKRole-<mgmt-cluster-name> \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "capabilities.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'

aws iam attach-role-policy \
  --role-name AmazonEKSCapabilityACKRole-<mgmt-cluster-name> \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

This role is used by the ACK and kro capabilities on the management cluster (configured in CDK). You do not put the role ARN directly in `values.yaml` — instead, set `mgmtCluster.kroRoleSessionARN` to the derived session ARN (`arn:aws:sts::<account>:assumed-role/<role-name>/KRO`) as emitted by the `KROSessionARN` CDK output. Per-workload-cluster ACK roles are created automatically by the kro `WorkloadCluster` RGD.

#### Installing the Capabilities

Once the roles exist, install both capabilities on the management cluster:

```bash
aws eks create-capability \
  --cluster-name <mgmt-cluster-name> \
  --capability-name <mgmt-cluster-name>-argocd \
  --capability-type ARGOCD \
  --role-arn arn:aws:iam::<account-id>:role/AmazonEKSCapabilityArgoCDRole-<mgmt-cluster-name> \
  --configuration '{
    "argoCD": {
      "namespace": "argocd",
      "awsIDC": {
        "idcInstanceARN": "<your-idc-instance-arn>",
        "idcRegion": "us-east-1"
      }
    }
  }' \
  --region <region>

aws eks create-capability \
  --cluster-name <mgmt-cluster-name> \
  --capability-name <mgmt-cluster-name>-ack \
  --capability-type ACK \
  --role-arn arn:aws:iam::<account-id>:role/AmazonEKSCapabilityACKRole-<mgmt-cluster-name> \
  --region <region>
```

Grant the ArgoCD role cluster-admin on the management cluster so it can deploy resources:

> **Important:** Without this step, ArgoCD will fail with `services is forbidden` errors — it cannot deploy any resources to the management cluster until this access entry exists.

```bash
aws eks create-access-entry \
  --cluster-name <mgmt-cluster-name> \
  --principal-arn arn:aws:iam::<account-id>:role/AmazonEKSCapabilityArgoCDRole-<mgmt-cluster-name> \
  --type STANDARD \
  --region <region>

aws eks associate-access-policy \
  --cluster-name <mgmt-cluster-name> \
  --principal-arn arn:aws:iam::<account-id>:role/AmazonEKSCapabilityArgoCDRole-<mgmt-cluster-name> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope '{"type": "cluster"}' \
  --region <region>
```

### Bare Metal Servers

- **Redfish-compatible BMC** (e.g., Dell iDRAC, HPE iLO)
- Network connectivity to the EKS VPC (L2 adjacency or routed)
- Known MAC addresses, IP assignments, BMC addresses and credentials

### Tools

- `kubectl` configured for the management cluster
- `helm` (v3)
- `yq` ([mikefarah/yq](https://github.com/mikefarah/yq))
- `git` with access to your repository

---

## 4. Deployment Guide

### Phase 1: Configure `values.yaml`

```bash
git clone <this-repo>
cd eks-h-bare-metal
cp values.example.yaml values.yaml
```

Edit `values.yaml` with your environment details:

```yaml
git:
  repoURL: "https://github.com/myorg/eks-bare-metal.git"
  branch: main

aws:
  accountId: "123456789012"
  region: us-west-2
  vpcId: vpc-0abc123def456
  subnets:
    - subnet-0aaa111
    - subnet-0bbb222

mgmtCluster:
  name: my-mgmt-cluster
  arn: arn:aws:eks:us-west-2:123456789012:cluster/my-mgmt-cluster
  kroRoleSessionARN: arn:aws:sts::123456789012:assumed-role/AmazonEKSCapabilityACKRole-my-mgmt-cluster/KRO
  argoCDCapabilityRoleARN: arn:aws:iam::123456789012:role/AmazonEKSCapabilityArgoCDRole-my-mgmt-cluster

argoCD:
  idcInstanceARN: arn:aws:sso:::instance/ssoins-abc123
  idcRegion: us-east-1
  rbacRoleMappings:
    - role: ADMIN
      identities:
        - id: <your-sso-user-id>
          type: SSO_USER

accessEntries:
  adminPrincipals:
    - arn:aws:iam::123456789012:user/myuser

bareMetalNetwork:
  cidr: "192.168.31.0/24"

hybridPodCIDR: "172.16.0.0/16"

workloadClusters:
  workload-cluster-1:
    serverGroups:
      - site-group-1
```

Server definitions live in `server-groups/<cluster>/<group>.yaml` — see `server-groups/example.yaml` for the format. Create `server-groups/workload-cluster-1/site-group-1.yaml` with your server entries (see Phase 2 below).

To find the IAM role ARNs for the ArgoCD and ACK capabilities, check the management cluster's existing capabilities:

```bash
aws eks list-capabilities --cluster-name my-mgmt-cluster --region us-west-2
```

### Phase 2: Generate Server Group Files

The bare-metal Helm charts need per-group values files accessible from Git. Create the file directly:

```bash
mkdir -p server-groups/<cluster-name>
# Create server-groups/<cluster-name>/<group-name>.yaml — see server-groups/example.yaml for the format
```

Commit and push; ArgoCD will pick it up automatically.

### Phase 3: Push to Git

```bash
git add -A
git commit -m "Initial site configuration"
git remote set-url origin <your-repo-url>
git push
```

### Phase 4: Bootstrap the Management Cluster (one-time, manual)

These resources must be applied manually with `kubectl` because ArgoCD needs them to exist before it can manage anything:

```bash
helm template eks-h-bare-metal charts/mgmt-bootstrap/ -f values.yaml | kubectl apply -f -
```

**What this does:**
- Creates a Secret that registers the management cluster as a deployment target in ArgoCD (using the cluster ARN as the server address)
- Creates the `eks-h-bare-metal` Application that renders the Helm chart and deploys all workload cluster resources

After this, everything else is GitOps-driven.

### Phase 5: Workload Cluster Creation (automatic)

The management ArgoCD renders the charts and applies all resources via ACK:

| Wave | Resource | What It Does |
|------|----------|--------------|
| -2 | IAM Roles (`cluster-role`, `nodegroup-role`, `ebs-csi-role`, `hybrid-nodes-role`, `ssm-job-role`, `aws-lbc-role`) | Creates per-cluster IAM roles |
| -2 | Security Group (`hybrid-nodes-sg`) | Allows traffic from bare metal node/pod CIDRs |
| -1 | EKS Cluster | Creates the workload EKS cluster with hybrid node support (`remoteNetworkConfig`) |
| 0 | Addons (VPC CNI, Pod Identity Agent, EBS CSI) | Installs EKS managed addons |
| 0 | Nodegroup | Creates EC2 managed node group (labeled `role: workload`) |
| 1 | Capabilities (ArgoCD, ACK) | Installs ArgoCD and ACK as EKS Capabilities on the workload cluster |
| 2 | Access Entries | Grants cluster-admin to ArgoCD role, admin users, and hybrid nodes role |
| 2 | Pod Identity Associations | Maps service accounts to IAM roles for SSM Jobs and LB Controller |
| 3 | Cluster Registration Secret | Registers the workload cluster in the management ArgoCD |
| 3 | Bootstrap Application | Deploys the workload cluster's own ArgoCD bootstrap |

### Phase 6: Workload Cluster Self-Bootstraps (automatic)

Once the workload cluster's ArgoCD Capability is active:

1. The management ArgoCD deploys the bootstrap Application to the workload cluster
2. This bootstrap renders the charts with `renderOnly=bootstrap-<cluster>`, which creates:
   - A Secret registering the workload cluster in its own ArgoCD
   - A root Application that renders the charts with `renderOnly=apps-<cluster>`
3. The workload ArgoCD deploys all components in sync wave order:

| Wave | Application | Description |
|------|-------------|-------------|
| -10 | `cert-manager` | PKI infrastructure for Tinkerbell mTLS |
| -8 | `cilium-cni` | CNI for hybrid nodes (cluster-pool IPAM, pod CIDR from `hybridPodCIDR`) |
| -8 | `aws-load-balancer-controller` | Provisions NLBs for Tinkerbell services |
| -6 | `tinkerbell-bare-metal-rbac` | ServiceAccount + RBAC for SSM/endpoint Jobs |
| -5 | `tinkerbell-stack` | Tinkerbell Helm chart (Smee, Rufio, Tink Server, Tootles, HookOS) |
| -4 | `tinkerbell-endpoint-sync` | PostSync Job that resolves NLB IP and patches Tinkerbell deployment |
| -4 | `action-registry` | Local container registry for Tinkerbell action images |
| -3 | `image-server` | Nginx serving Ubuntu cloud image + driver packages via NLB |
| 0 | `tinkerbell-mtls` | cert-manager Issuer + Certificates for Tink Server TLS |
| 1 | `kro` | kro controller (Kube Resource Orchestrator) |
| 2 | `bare-metal-kro` | BareMetalServer ResourceGraphDefinition (registers the CRD) |
| 3 | `bare-metal` | ApplicationSet — Templates, PreSync Jobs, BareMetalServer instances per server group |

### Phase 7: Bare Metal Provisioning (automatic)

Once the Tinkerbell stack is running and server group files exist:

1. The bare-metal ApplicationSet creates one ArgoCD app per server group
2. PreSync Jobs resolve NLB endpoints and create SSM activations (written to ConfigMaps)
3. Helm renders Tinkerbell Templates and `BareMetalServer` kro instances
4. kro reconciles each instance: waits for ConfigMaps → creates BMC Secret, Machine, Hardware → creates Workflow with real NLB IPs
5. Tinkerbell provisions the server (ISO boot → OS install → cloud-init → EKS join)

---

## 5. Adding a New Workload Cluster

Add a new entry under `workloadClusters` in `values.yaml`:

```yaml
workloadClusters:
  workload-cluster-1:
    # ... existing ...
  workload-cluster-2:
    # Optional: override NLB subnets (defaults to aws.subnets)
    # tinkerbellSubnets:
    #   - subnet-0ccc333
    #   - subnet-0ddd444
    serverGroups:
      - rack-1
```

Then create `server-groups/workload-cluster-2/rack-1.yaml` with the server definitions (see `server-groups/example.yaml` for the format):

```yaml
cluster:
  name: workload-cluster-2
  region: us-west-2
  hybridNodesRole: workload-cluster-2-hybrid-nodes-role
groupName: rack-1
servers:
  - name: server-1
    machineProfile: poweredge-xr8000r-2disk
    osProfile: ubuntu-noble
    networkProfile: my-network
    ip: 192.168.31.200
    mac: "aa:bb:cc:dd:ee:ff"
    bmcAddress: 192.168.30.50
    bmcUser: root
    bmcPass: <your-bmc-password>
    provision: false
    provisionHash: "v1"
```

Then commit and push:

```bash
git add -A && git commit -m "Add workload-cluster-2" && git push
```

The Helm chart will generate all resources for the new cluster — IAM roles, EKS cluster, capabilities, ArgoCD Applications, and bare metal provisioning — automatically.

---

## 6. Adding Bare Metal Servers

### Add to an Existing Server Group

Edit `server-groups/<cluster>/<group>.yaml` and add a server entry to the `servers:` list:

```yaml
cluster:
  name: workload-cluster-1
  region: us-west-2
  hybridNodesRole: workload-cluster-1-hybrid-nodes-role
groupName: site-group-1
servers:
  - name: dell-server-1
    # ... existing ...
  - name: dell-server-2          # ← add new server
    machineProfile: poweredge-xr8000r-2disk
    osProfile: ubuntu-noble
    networkProfile: sjc38-dell-subnet
    ip: 192.168.31.152
    mac: "50:7c:6f:78:2c:39"
    bmcAddress: 192.168.30.13
    bmcUser: root
    bmcPass: <your-bmc-password>
    provision: false
    provisionHash: "v1"
```

Then commit and push:

```bash
git add -A && git commit -m "Add dell-server-2" && git push
```

ArgoCD will create the new Hardware, Machine, Workflow, and SSM activation automatically.

### Create a New Server Group

Add a new group name to `serverGroups` in `values.yaml`, then create the corresponding file in `server-groups/<cluster>/`:

```yaml
workloadClusters:
  workload-cluster-1:
    serverGroups:
      - site-group-1    # existing
      - site-group-2    # ← new group
```

Then create `server-groups/workload-cluster-1/site-group-2.yaml` with the server entries (same format as the existing group file).

The ApplicationSet will automatically generate new inventory and provision Applications for it.

### Adding a New Machine Profile

If you have different hardware (different disk layout, drivers, etc.), add a profile to the bare-metal chart values:

```yaml
# In generic-platform-definitions/tinkerbell/bare-metal/values.yaml
machineProfiles:
  poweredge-r760-4disk:
    dest_disk: /dev/sda
    root_partition: /dev/sda1
    boot_partition: /dev/sda16
    kernel_path: /vmlinuz-6.8.0-101-generic
    initrd_path: /initrd.img-6.8.0-101-generic
    drivers: []
```

### Adding a New OS Profile

```yaml
osProfiles:
  my-os:
    archive: my-os-eks-1.35-amd64.tar.gz
    archiveType: targz
    archiveChecksum: "sha256:abc123..."   # from image build output (.sha256 file)
    kernelPath: /boot/vmlinuz
    initrdPath: /boot/initrd.img
    fsType: ext4
    rootSetup:
      password: ""                        # set per your security policy
      permitRootLogin: false
```

The `archive` filename must match a file in the S3 image bucket. Build images using the image-builder pipeline (see `image-builder/README.md`), then set `archive` and `archiveChecksum` from the build output. The image-server sidecar syncs from S3 every 5 minutes and serves the archive to Tinkerbell workflows via internal NLB.

### Adding a New Network Profile

```yaml
networkProfiles:
  my-network:
    gateway: 10.0.0.1
    netmask: 255.255.255.0
    netmaskCIDR: "24"
    dns:
      - 10.0.0.1
```

---

## 7. Re-provisioning a Server

To re-provision a server, delete its Workflow. kro will automatically recreate it with valid NLB endpoints:

```bash
kubectl delete workflow provision-<server-name> -n tinkerbell \
  --context arn:aws:eks:<region>:<account-id>:cluster/<workload-cluster-name>
```

kro detects the missing Workflow and recreates it as part of its reconciliation loop. Since the `tinkerbell-endpoints` ConfigMap already exists with resolved NLB IPs, the new Workflow is created with correct URLs immediately — no manual sync needed.

To fully tear down and recreate all resources for a server, delete the `BareMetalServer` instance and re-sync the ArgoCD app:

```bash
kubectl delete baremetalserver <server-name> -n tinkerbell \
  --context arn:aws:eks:<region>:<account-id>:cluster/<workload-cluster-name>
# ArgoCD self-heal recreates the BareMetalServer instance, kro recreates all child resources
```

The inventory resources (Hardware, Machine, BMC Secret) are managed by kro and will be recreated automatically.

---

## 8. Decommissioning a Workload Cluster

Deleting a workload cluster requires care to avoid orphaned AWS resources (NLBs, security groups) created by the AWS Load Balancer Controller on the workload cluster.

The bootstrap app is owned by kro (not ArgoCD) and cannot be deleted independently — kro will recreate it. The correct approach is to remove the cluster from `values.yaml` and let the deletion cascade through ArgoCD → kro → workload cluster cleanup.

### Step 1: Remove from values.yaml and push

Remove the cluster entry from `workloadClusters` in `values.yaml`, commit, and push. Then trigger an ArgoCD sync (or wait for auto-sync):

```bash
# After pushing the values.yaml change:
kubectl patch application eks-h-bare-metal -n argocd --type=merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"prune":true}}}'
```

ArgoCD prunes the WorkloadCluster CR. kro begins reverse-DAG deletion:

> **Note:** If this is the last workload cluster, ArgoCD will block auto-sync with "auto-sync will wipe out all resources" because the chart renders zero resources. In this case, trigger a manual sync from the ArgoCD UI: open the `eks-h-bare-metal` app → **Sync** → check **Prune** → **Synchronize**.
1. Deletes `bootstrapApp` → workload ArgoCD prunes all apps → LBC starts deleting NLBs
2. Deletes capabilities, nodegroup, addons
3. Deletes EKS cluster, IAM roles, security group

### Step 2: Clean up orphaned NLBs

kro does not wait for NLB deletion to complete before deleting the EKS cluster. NLBs created by the AWS Load Balancer Controller on the workload cluster **will be orphaned** and must be cleaned up manually:

```bash
# List orphaned NLBs in the VPC
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?VpcId=='<vpcId>'].[LoadBalancerName,LoadBalancerArn,State.Code]" \
  --output table

# Delete them
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?VpcId=='<vpcId>'].LoadBalancerArn" \
  --output text | xargs -I{} aws elbv2 delete-load-balancer --load-balancer-arn {} --region <region>
```

Also check for orphaned security groups created by LBC (tagged with the cluster name):

```bash
aws ec2 describe-security-groups --region <region> \
  --filters "Name=vpc-id,Values=<vpcId>" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
  --query "SecurityGroups[?contains(Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0], '<cluster>')].[GroupId,GroupName]" \
  --output table
```

If Grafana integration was enabled, the Grafana Operator registered data sources and dashboards in Amazon Managed Grafana. These are not cleaned up automatically — remove them manually from the AMG console or API:
- Delete the data source named after the cluster
- Delete dashboards provisioned for the cluster

### Step 3: Handle stuck finalizer (if needed)

If the WorkloadCluster CR gets stuck in `Deleting` state (kro's finalizer waits for resources on the now-deleted cluster):

```bash
kubectl patch workloadcluster <cluster> -n default --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

Full deletion takes ~15-20 minutes (EKS cluster deletion is the slowest part).

---

## 9. Component Reference

### Repository Structure

```
eks-h-bare-metal/
├── README.md
├── CHANGELOG.md
├── USER-GUIDE.md                           # This document
│
├── cdk/                                    # Management cluster and image-builder CDK stacks
│   ├── bin/mgmt-cluster.ts
│   ├── lib/mgmt-cluster-stack.ts
│   ├── lib/image-builder-stack.ts
│   ├── lib/image-mirror-stack.ts
│   ├── config.example.yaml
│   └── README.md
│
├── charts/                                 # Helm charts (one per ArgoCD app)
│   ├── mgmt-bootstrap/                     # ArgoCD root app + cluster registration (manual apply)
│   ├── mgmt-workload-clusters/             # kro WorkloadCluster CR + admin access per cluster
│   ├── workload-apps/                      # All ArgoCD Applications per workload cluster
│   └── workload-bootstrap/                 # Workload cluster ArgoCD self-bootstrap
│
├── values.yaml                             # ← YOUR SITE CONFIGURATION (gitignored)
├── values.example.yaml
│
├── generic-platform-definitions/           # Reusable, cluster-agnostic components
│   ├── infrastructure/
│   │   └── workload-cluster-kro/           # WorkloadCluster RGD (EKS + IAM + SG + nodegroup + capabilities)
│   ├── observability/                      # Grafana dashboards + AMP config (Helm chart)
│   ├── platform-values/                    # Machine / OS / network / tuning profiles
│   └── tinkerbell/
│       ├── stack/                          # Tinkerbell Helm values
│       ├── stack-bootstrap/                # NLB endpoint sync Job + RBAC
│       ├── cilium/                         # Cilium CNI values for hybrid nodes
│       ├── mtls/                           # cert-manager resources for Tink TLS
│       ├── image-server/                   # Nginx + S3 sync sidecar for OS images
│       ├── registry/                       # Local container registry (action images)
│       ├── bare-metal-rbac/                # RBAC for SSM/endpoint Jobs
│       ├── bare-metal-kro/                 # kro RGDs: BareMetalInventory, BareMetalProvision, BareMetalDeprovision
│       └── bare-metal/                     # Helm chart: Templates, PreSync Jobs, BareMetal* CR instances
│
├── image-builder/                          # OS image build pipeline (CodeBuild)
│   ├── os-image-build.sh                   # Image customization script
│   ├── os-image-buildspec.yml              # CodeBuild buildspec for OS images
│   ├── mirror-images.py                    # Container image mirror script
│   ├── mirror-images.yaml                  # Mirror source/tag definitions
│   ├── mirror-buildspec.yml                # CodeBuild buildspec for mirror pipeline
│   ├── images.yaml                         # Source image URLs and checksums
│   ├── load-config.py                      # Config loader for buildspec
│   └── README.md                           # Pipeline docs, ownership model, security controls
│
├── server-groups/                          # Per-cluster server group definitions (gitignored except example.yaml)
│   ├── example.yaml
│   └── <cluster>/<group>.yaml              # Source of truth for bare metal inventory
│
└── scripts/
    └── provision-timing.sh                 # End-to-end provisioning timeline from Workflow labels
```

### How the Helm Chart Renders

The same Helm chart is rendered by three different ArgoCD instances with different `renderOnly` values:

| ArgoCD Instance | `renderOnly` | What Gets Rendered |
|-----------------|--------------|-------------------|
| Management cluster | _(not set)_ | All management-level resources: IAM roles, EKS clusters, capabilities, access entries, bootstrap apps |
| Workload cluster (bootstrap) | `bootstrap-<cluster>` | Local cluster registration + root app for the workload ArgoCD |
| Workload cluster (apps) | `apps-<cluster>` | All ArgoCD Applications: cert-manager, Cilium, Tinkerbell, bare-metal ApplicationSets |

### Key Endpoints

| Service | Type | Purpose |
|---------|------|---------|
| Tinkerbell (Smee HTTP) | NLB | Serves HookOS ISO to bare metal via Redfish Virtual Media |
| Tinkerbell (Tink Server gRPC) | NLB | Workflow orchestration — HookOS tink-worker connects here |
| Tinkerbell (Tootles) | NLB | Metadata service — cloud-init queries this for Hardware userData |
| Image Server (nginx) | NLB | Serves Ubuntu cloud image + driver packages to bare metal |

All NLBs use `instance` target type to preserve client source IP (required for Tootles hardware matching).

### Action Image Pipeline

Tinkerbell workflow actions (partition, write, kexec, etc.) run as containers on HookOS during bare metal provisioning. HookOS has no internet access, so action images must be served locally via the action-registry.

```
Public registry ──[mirror pipeline]──▶ Private ECR ──[action-registry seed]──▶ Local registry ──[tink-agent]──▶ HookOS
```

**How it works:**

1. A CodeBuild mirror pipeline copies public images to private ECR (configured in `image-builder/mirror-images.yaml`)
2. The `action-registry` deployment runs an `ecr-login` init container (aws-cli) that obtains an ECR auth token via IMDS and writes it to a shared volume
3. A `seed-images` sidecar (skopeo) reads the ECR auth token and copies images from ECR into a local registry (registry:2) running as a sidecar on `localhost:5000`. Images are stored under their short name (last path segment, e.g. `writefile:v1.0.0`). The container exits with an error if any image fails to copy.
4. The action-registry Service is exposed via an internal NLB on port 5000
5. The `endpoint-sync` Job (PostSync hook, wave -4) resolves the NLB IP, writes it to the `tinkerbell-endpoints` ConfigMap, and patches all `bare-metal-site-group-*` ArgoCD Applications with `registryAddress=<IP>:5000` as a Helm parameter
6. Workflow templates use `{{ $registry }}` (from `$.Values.registryAddress`, set by step 5) to prefix `actionImages` short names — e.g. `10.100.34.252:5000/disk-tools:3.20`
7. tink-agent on HookOS pulls images over HTTP from `<registryIP>:5000/<name>:<tag>` (the IP is in `insecure_registries` so Docker uses HTTP, not HTTPS)

Note: `registryAddress` is set to `""` in the bare-metal chart defaults. The chart will fail to render with `registryAddress must be set` until the endpoint-sync Job patches the ArgoCD Application. This is intentional — it prevents deploying with a stale or missing registry address. On first deploy, the bare-metal apps may not exist when endpoint-sync runs; they will be patched on the next sync cycle.

**Configuration files:**

| Stage | Config file | What to set | Example |
|-------|-------------|-------------|---------|
| 1. Mirror to ECR | `image-builder/mirror-images.yaml` | Public source URI + tags | `source: quay.io/tinkerbell-actions/writefile`, `tags: ["v1.0.0"]` |
| 2. Seed action-registry | `values.yaml` → `workloadClusters.<name>.seedImages` | Full ECR URI | `833542146025.dkr.ecr.../.../writefile:v1.0.0` |
| 3. Workflow templates | `generic-platform-definitions/tinkerbell/bare-metal/values.yaml` → `actionImages` | Short name | `writefile:v1.0.0` |

`seedImages` lives in the top-level `values.yaml` under each workload cluster because the `action-registry-config` ConfigMap is templated by `charts/workload-apps/templates/apps.yaml`, which reads from the workload cluster entry. `actionImages` lives in the bare-metal chart's `values.yaml` because it's consumed by the Tinkerbell workflow templates rendered per server group.

The short name in `actionImages` must match the last path segment of the `seedImages` URI — the seed container strips the ECR prefix when storing images locally (via `sed 's|.*/||'`). The registry address (`registryAddress`) is not configured manually — it's injected automatically by the `endpoint-sync` Job as a Helm parameter on the ArgoCD Application after resolving the action-registry NLB IP.

**To add a new action image:**

1. Add the public source to `image-builder/mirror-images.yaml`:
   ```yaml
   my-action:
     source: quay.io/my-org/my-action
     tags: ["v1.0.0"]
     arch: amd64
   ```
2. Run the mirror pipeline to copy it to ECR.
3. Add the ECR URI to `seedImages` under the workload cluster in `values.yaml`:
   ```yaml
   workloadClusters:
     my-cluster:
       seedImages:
         myAction: 833542146025.dkr.ecr.us-west-1.amazonaws.com/<prefix>/my-action:v1.0.0
   ```
4. Add the short name to `actionImages` in `generic-platform-definitions/tinkerbell/bare-metal/values.yaml`:
   ```yaml
   actionImages:
     myAction: my-action:v1.0.0
   ```
5. Reference in your workflow template as:
   ```
   image: {{ $registry }}/{{ $.Values.actionImages.myAction }}
   ```
   (`$registry` is set from `$.Values.registryAddress`, injected by the endpoint-sync Job)
6. Commit and push — ArgoCD syncs the ConfigMap (restarting action-registry to seed the new image) and updates the workflow templates.

**Which ArgoCD apps to sync after changes:**

| Changed file | ArgoCD app | Cluster |
|-------------|------------|---------|
| `values.yaml` (seedImages) | `<workload-cluster-name>` | Management |
| `bare-metal/values.yaml` (actionImages) | `<cluster>-bare-metal-site-group-*` | Workload |
| Registry IP changed (NLB recreated) | `<cluster>-tinkerbell-endpoint-sync` | Workload |

Sync the management app first so the action-registry seeds the new image before the workflow tries to use it. The `registryAddress` Helm parameter is set automatically by the endpoint-sync Job — you do not need to set it manually.

### ArgoCD ignoreDifferences

The Tinkerbell deployment env vars are patched at runtime by the endpoint sync Job and must be excluded from ArgoCD drift detection:

- `Deployment(tinkerbell).spec.template.spec.containers[0].env` — patched by endpoint sync Job

The `tinkerbell-stack` Application includes `RespectIgnoreDifferences=true` in syncOptions.

All bare metal resources (Hardware, Workflow, Machine, BMC Secret) are managed by kro, not directly by ArgoCD, so no `ignoreDifferences` are needed for them.

---

## 10. Observability

Each workload cluster is automatically provisioned with a monitoring stack. No manual configuration is needed — everything is created by kro and deployed by ArgoCD.

### AMP Workspace

An Amazon Managed Service for Prometheus (AMP) workspace is created per workload cluster via ACK. The workspace ID is exposed in the WorkloadCluster CR status:

```bash
kubectl get workloadcluster <cluster> -n default -o jsonpath='{.status.ampWorkspaceID}'
```

### EKS Control Plane Logging

All 5 EKS control plane log types are enabled and sent to CloudWatch Logs:
- API server (`api`)
- Audit (`audit`)
- Authenticator (`authenticator`)
- Controller manager (`controllerManager`)
- Scheduler (`scheduler`)

Logs are available in CloudWatch under `/aws/eks/<cluster-name>/cluster`.

### ADOT Collector

The AWS Distro for OpenTelemetry (ADOT) collector is deployed on each workload cluster. It scrapes Prometheus metrics and remote-writes them to the cluster's AMP workspace.

**Scrape targets:**

| Target | Port | Metrics | Discovery |
|--------|------|---------|-----------|
| Telegraf | `:9273` | CPU, memory, disk, network, ethtool (bare metal nodes) | Headless Service `telegraf-metrics` in `kube-system` |
| cAdvisor | via kubelet | Container CPU, memory, filesystem, network | Kubernetes node SD |
| Kubelet | `:10250` | Node-level kubelet metrics | Kubernetes node SD |
| kube-apiserver | `:443` | API server request latency, etcd, etc. | Kubernetes endpoints SD |

**Auto-discovery:** As hybrid nodes join or leave the cluster, the headless `telegraf-metrics` Service automatically updates its Endpoints. ADOT discovers the changes on its next scrape cycle (30s default).

**Authentication:** ADOT uses Pod Identity with `AmazonPrometheusRemoteWriteAccess` to authenticate to AMP via SigV4.

### Telegraf

Telegraf runs as a DaemonSet on hybrid nodes (deployed by the platform chart). It collects hardware-specific metrics not available from standard Kubernetes sources:

- CPU (per-core and total)
- Memory
- Disk (excluding tmpfs, devtmpfs, overlay)
- Network interfaces
- Ethtool (NIC-level counters, ring buffer stats, driver stats)

Metrics are exposed via Prometheus client on `:9273`.

### Grafana Operator

> **Optional.** The Grafana Operator is only deployed if `grafana.endpoint` is set in `values.yaml`. If omitted, AMP, ADOT, Telegraf, and control plane logging still work — you can query AMP directly with `awscurl` or add it as a data source in any Grafana instance manually.

The Grafana Operator runs on each workload cluster and manages the connection to Amazon Managed Grafana (AMG). It automatically:

- Registers the cluster's AMP workspace as a Prometheus data source in AMG
- Provisions dashboards from Git (create/update/delete lifecycle)
- Uses SigV4 authentication via the AMG workspace IAM role

**Prerequisites:**
1. An Amazon Managed Grafana workspace
2. A Grafana service account with Admin role and a token
3. The AMG workspace IAM role must have `AmazonPrometheusQueryAccess`

**Configuration** in `values.yaml`:
```yaml
grafana:
  endpoint: "https://g-xxxxx.grafana-workspace.us-west-2.amazonaws.com"
```

Create the token Secret on the workload cluster:
```bash
kubectl create secret generic grafana-service-account-token \
  -n monitoring --from-literal=token=<service-account-token>
```

**Dashboards** (6 total, stored in `generic-platform-definitions/observability/dashboards/`):

| Dashboard | Panels |
|-----------|--------|
| Workload Cluster Overview | Nodes, pods, CPU, memory, targets, API rate |
| Tinkerbell Stack | Per-component CPU/memory/network for tinkerbell, image-server, action-registry, hookos |
| EKS Cluster Status | Nodes, pods, CPU/memory by namespace, API latency p99 |
| Node Distribution | Nodes by instance type/zone, pods/CPU/memory per node |
| Infrastructure Overview | Multi-cluster summary, CPU/memory over time |
| Provisioning Status | Nodes, targets up/down, active pods, container restarts |

All dashboards have a **Data Source** dropdown (select which AMP workspace) and a **Cluster** dropdown (filter by cluster name).

### Querying Metrics

Use the AMP workspace endpoint with any Prometheus-compatible tool:

```bash
# Get the workspace ID
WS_ID=$(kubectl get workloadcluster <cluster> -n default -o jsonpath='{.status.ampWorkspaceID}')

# Query via awscurl
awscurl --service aps --region <region> \
  "https://aps-workspaces.<region>.amazonaws.com/workspaces/$WS_ID/api/v1/query?query=up"
```

Or use the dashboards in Amazon Managed Grafana.

---

## 11. Safe Rollout Architecture (Future)

The current architecture provisions all servers in a server group simultaneously when changes are pushed. For production environments requiring canary deployments, rolling batches, health gates, and automated rollback, a two-tier GitOps model with Argo Workflows is recommended.

### Current Limitations

- ArgoCD syncs all servers in a group at once — no sequential provisioning
- ArgoCD EKS Capability does not support custom health checks for kro CRs
- No automated rollback — manual intervention required on failure
- `provisionHash` changes trigger all affected servers simultaneously

### Two-Tier Architecture

```
Tier 1 (Source repo)                    Tier 2 (Rendered repo)
┌──────────────────────┐                ┌──────────────────────────────┐
│ values.yaml          │                │ rendered/<cluster>/          │
│ server-groups/       │   Argo         │   inventory/node-1.yaml     │
│   <cluster>/         │──Workflow──►   │   provision/node-1.yaml     │
│     group-1.yaml     │   renders      │   provision/node-2.yaml     │
│                      │   + gates      │   provision/node-3.yaml     │
└──────────────────────┘                └──────────────────────────────┘
                                                  │
                                            ArgoCD syncs
                                            (plain manifests)
```

**Tier 1** — the source of truth. Users edit `values.yaml` and `server-groups/` files, same as today.

**Tier 2** — rendered manifests. Contains one file per server per resource type (BareMetalInventory, BareMetalProvision CRs). ArgoCD applies whatever is in this repo — it no longer renders Helm charts for bare metal.

**Argo Workflows** — the orchestrator between the two tiers. It renders the Helm chart, commits servers to Tier 2 in controlled batches, and gates progression on health metrics from AMP.

### Rollout Sequence

1. User pushes a change to Tier 1 (e.g., adds 5 servers with `provision: true`)
2. Git webhook triggers an Argo Workflow
3. Workflow renders all bare-metal CRs via `helm template`
4. **Canary phase:** commits 1 server to Tier 2
   - ArgoCD syncs → kro creates the BareMetalProvision CR → Tinkerbell provisions
   - Workflow polls AMP health gates (node joined, Telegraf reporting, CPU/memory normal)
   - Soak period (configurable, e.g., 15 minutes)
5. **Rolling phase:** commits remaining servers in batches (configurable batch size)
   - Each batch: commit → ArgoCD sync → health gate → proceed or rollback
6. **On failure:** Workflow reverts the Tier 2 commits. ArgoCD prunes the removed CRs. kro handles deprovisioning.

### Health Gates (via AMP)

Since AMP, ADOT, and Telegraf are already deployed, the Workflow queries AMP for health signals:

| Gate | PromQL Query | Pass Criteria |
|------|-------------|---------------|
| Node joined EKS | `up{job="kubelet", node="<name>"}` | == 1 for 2 min |
| Telegraf reporting | `up{job="telegraf", instance=~"<ip>.*"}` | == 1 for 2 min |
| CPU healthy | `cpu_usage_idle{host="<name>"}` | > 10% for 5 min |
| Memory healthy | `mem_used_percent{host="<name>"}` | < 90% for 5 min |
| No crash loops | `kube_pod_container_status_restarts_total` delta | < 3 in 10 min |

### Rollback

Bare metal rollback differs from application rollback — there is no instant container image swap.

- **Stop rollout:** Workflow reverts uncommitted batches in Tier 2. Canary stays provisioned, fleet unchanged.
- **Re-provision with previous image:** Change `osProfile.archive` back to the previous version, bump `provisionHash`. Server is wiped and re-imaged.
- **Drain and cordon:** If the node joined but is unhealthy, `kubectl cordon` + `kubectl drain` removes it from scheduling without re-provisioning.

### What Changes from Current Architecture

| Component | Current | Two-Tier |
|-----------|---------|----------|
| Bare-metal ArgoCD app | Helm source (renders chart) | Directory source (plain manifests from Tier 2) |
| Render responsibility | ArgoCD | Argo Workflow |
| Rollout control | All-at-once | Canary → rolling batches with health gates |
| Rollback | Manual (`provision: false` + push) | Automated (Workflow reverts Tier 2 commits) |
| Health verification | None (ArgoCD can't check kro CR health) | AMP queries between batches |
| Non-bare-metal apps | ArgoCD (unchanged) | ArgoCD (unchanged) |

### Implementation Requirements

- **Argo Workflows** deployed on the management cluster
- **Argo Events** deployed on the management cluster (Git webhook sensor to trigger Workflows)
- **Tier 2 Git repository** (CodeCommit or same repo on a separate branch)
- **Git write credentials** for the Workflow to push to Tier 2
- **AMP query credentials** for health gate evaluation (Pod Identity with `AmazonPrometheusQueryAccess`)
- **WorkflowTemplate** defining canary count, batch size, soak period, health queries, and rollback behavior

### Maintenance Windows

Argo Workflows does not have built-in maintenance windows, but the architecture supports them through ArgoCD Sync Windows:

- **ArgoCD Sync Windows** (native) — configure `allow`/`deny` schedules per application or project on the workload cluster's ArgoCD. The Workflow can commit to Tier 2 at any time, but ArgoCD only applies changes during the allowed window. This is the simplest approach.
- **CronWorkflow** — schedule Argo Workflows to only run during allowed windows (e.g., `schedule: "0 2 * * SAT"`). Changes accumulate in Tier 1 and are rendered/rolled out only during the window.
- **Argo Events time filter** — the event sensor that triggers workflows from Git webhooks can filter by time, queuing events outside the maintenance window.

The practical combination: Argo Workflows controls sequencing, ArgoCD Sync Windows control timing.

### Deployment Location

| Component | Cluster | Why |
|-----------|---------|-----|
| Argo Workflows controller | Management | Orchestrates across workload clusters, needs access to Tier 1/2 repos and AMP |
| Argo Events (sensor + event source) | Management | Receives Git webhooks, triggers Workflows |
| ArgoCD Sync Windows | Workload (per-cluster) | Controls when bare-metal apps actually sync |
| WorkflowTemplates | Management | Defines rollout strategy, health gates, rollback |

All orchestration components run on the management cluster. Workload clusters need no additional components — ArgoCD sync window support is built in.

This architecture follows the same pattern used in large-scale bare metal operations (telecom, edge computing): GitOps for desired state, workflow engine for sequencing, metrics for health gates.

## 12. Troubleshooting

### Cluster creation is slow / Capabilities keep failing

ACK resources are applied in sync wave order, but Capabilities require the cluster to be ACTIVE. Check ACK status:

```bash
kubectl get cluster,capability,addon -n default \
  --context arn:aws:eks:<region>:<account-id>:cluster/<mgmt-cluster>
```

Look for `ACK.Recoverable` conditions — these will auto-resolve once the cluster is ready.

### SSM activation Job fails

Check Job logs:

```bash
kubectl logs job/<server-name>-ssm-activation -n tinkerbell \
  --context arn:aws:eks:<region>:<account-id>:cluster/<workload-cluster>
```

Common causes:
- Pod Identity not yet active (Pod Identity Agent addon still installing)
- IAM role doesn't exist yet (ACK hasn't created it)
- Hardware resource doesn't exist (inventory app hasn't synced yet)

### Endpoint resolver Job fails

```bash
kubectl logs job/<group-name>-resolve-endpoints -n tinkerbell \
  --context arn:aws:eks:<region>:<account-id>:cluster/<workload-cluster>
```

This is a PreSync Job — it runs before the bare-metal app syncs. Common causes:
- NLB not yet provisioned (AWS LB Controller still starting)
- DNS resolution fails (NLB hostname not yet resolvable)
- RBAC missing (ServiceAccount needs `configmaps` permission)

### kro BareMetalServer stuck in Progressing

Check the instance status:

```bash
kubectl get baremetalserver <server-name> -n tinkerbell -o jsonpath='{.status.conditions}' \
  --context arn:aws:eks:<region>:<account-id>:cluster/<workload-cluster>
```

Common causes:
- `tinkerbell-endpoints` ConfigMap doesn't exist (endpoint resolver Job hasn't run)
- `<server>-ssm` ConfigMap doesn't exist (SSM activation Job hasn't run)
- RGD is `Inactive` (check `kubectl get rgd bare-metal-server` for validation errors)

### Server doesn't boot HookOS

Check Rufio Machine status:

```bash
kubectl get machine.bmc -n tinkerbell \
  --context arn:aws:eks:<region>:<account-id>:cluster/<workload-cluster>
```

Verify BMC connectivity from a workload cluster node:

```bash
curl -k https://<bmc-address>/redfish/v1/Systems
```

### Server boots but doesn't join EKS

1. Check cloud-init logs on the server: `/var/log/cloud-init-output.log`
2. Verify SSM activation hasn't expired (2h TTL)
3. Check that the hybrid nodes IAM role has the required policies
4. Verify the HYBRID_LINUX access entry exists on the workload cluster
5. Check that `remoteNetworkConfig` is enabled on the cluster
