# CDK Bootstrap Stack for EKS-H Management Cluster

Creates the management/seed EKS cluster with ArgoCD, ACK, and kro capabilities.
No compute nodes are needed — all capabilities run on AWS-managed infrastructure.

## Prerequisites

- AWS CDK v2 installed (`npm install -g aws-cdk`)
- An existing VPC with at least 2 subnets
- An IAM Identity Center instance with users/groups configured
- Node.js 18+

## Usage

```bash
cd cdk
npm install
cp config.example.yaml config.yaml
# Edit config.yaml with your values
cdk deploy
```

After deploy, run the `BootstrapCommand` from the stack outputs to initialize ArgoCD.

## config.yaml

```yaml
clusterName: eks-h-bare-metal
region: us-west-2
vpcId: vpc-0abc123
subnetIds:
  - subnet-aaa
  - subnet-bbb
idcInstanceARN: arn:aws:sso:::instance/ssoins-abc123
idcRegion: us-east-1
rbacRoleMappings:
  - role: ADMIN
    identities:
      - id: c488d4b8-4021-7016-be5e-9084fdd4db1e
        type: SSO_USER
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `clusterName` | yes | | Management cluster name |
| `region` | no | `CDK_DEFAULT_REGION` | AWS region |
| `vpcId` | yes | | Existing VPC ID |
| `subnetIds` | yes | | List of subnet IDs |
| `idcInstanceARN` | yes | | IAM Identity Center instance ARN |
| `idcRegion` | no | `us-east-1` | IDC region |
| `kubernetesVersion` | no | `1.35` | EKS version |
| `rbacRoleMappings` | yes | | ArgoCD RBAC — maps IDC users/groups to roles |

## What it creates

- **CodeCommit repository** (named after `clusterName`)
- **IAM roles**: ArgoCD capability role, ACK capability role, EKS cluster role
- **EKS cluster** (no nodegroup — capabilities are AWS-managed)
- **Capabilities**: ArgoCD (with IDC SSO + RBAC), ACK, kro
- **Access entry**: ArgoCD role gets cluster-admin

## Outputs

| Output | maps to `values.yaml` |
|--------|----------------------------|
| `ClusterName` | `mgmtCluster.name` |
| `ClusterARN` | `mgmtCluster.arn` |
| `ArgoCDCapabilityRoleARN` | `mgmtCluster.argoCDCapabilityRoleARN` |
| `ACKCapabilityRoleARN` | _(management cluster only — not in values.yaml)_ |
| `KROSessionARN` | `mgmtCluster.kroRoleSessionARN` |
| `CodeCommitRepoURL` | `git.repoURL` |
| `Region` | `aws.region` |
| `AccountId` | `aws.accountId` |
| `VpcId` | `aws.vpcId` |
| `Subnets` | `aws.subnets` |
| `BootstrapCommand` | Run after deploy to initialize ArgoCD |

## Teardown

The CDK app creates three stacks. Destroy them in reverse order. Some resources use `RETAIN` policies and must be cleaned up manually.

**Prerequisites:** Decommission all workload clusters first (see USER-GUIDE.md §8). The management cluster must have no active workload clusters or ArgoCD applications before teardown.

### Step 1: Delete EKS Capabilities

Capabilities have `deletePropagationPolicy: RETAIN`, so they are not removed by `cdk destroy`. Delete them manually first:

```bash
CLUSTER=<clusterName from config.yaml>
REGION=<region>

aws eks delete-capability --cluster-name $CLUSTER --capability-name $CLUSTER-argocd --region $REGION
aws eks delete-capability --cluster-name $CLUSTER --capability-name $CLUSTER-ack --region $REGION
aws eks delete-capability --cluster-name $CLUSTER --capability-name $CLUSTER-kro --region $REGION

# Wait for capabilities to be fully deleted
aws eks list-capabilities --cluster-name $CLUSTER --region $REGION
```

### Step 2: Destroy CDK stacks

```bash
cd cdk
cdk destroy "$CLUSTER-image-mirror" "$CLUSTER-image-builder" "$CLUSTER-mgmt"
```

### Step 3: Clean up retained resources

These resources have `RETAIN` removal policies and survive `cdk destroy`:

| Resource | Stack | Why retained | Manual cleanup |
|----------|-------|-------------|----------------|
| S3 image bucket | image-builder | Prevent accidental image loss | `aws s3 rb s3://<ImageBucketName> --force` |
| ECR repositories | image-mirror | Prevent loss of mirrored images | `aws ecr delete-repository --repository-name <repo> --force` (one per image in `mirror-images.yaml`) |
| CodeCommit repo | mgmt | Prevent loss of Git history | `aws codecommit delete-repository --repository-name $CLUSTER` |

### Step 4: Clean up IAM roles (if needed)

If `cdk destroy` fails to delete IAM roles due to lingering instance profiles or policies:

```bash
# List and detach any remaining policies
aws iam list-attached-role-policies --role-name <role-name>
aws iam detach-role-policy --role-name <role-name> --policy-arn <policy-arn>
aws iam delete-role --role-name <role-name>
```
