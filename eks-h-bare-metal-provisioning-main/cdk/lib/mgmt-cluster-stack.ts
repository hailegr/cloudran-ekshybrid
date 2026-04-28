import * as cdk from "aws-cdk-lib";
import * as eks from "aws-cdk-lib/aws-eks";
import * as iam from "aws-cdk-lib/aws-iam";
import * as codecommit from "aws-cdk-lib/aws-codecommit";
import { Construct } from "constructs";

export interface MgmtClusterStackProps extends cdk.StackProps {
  clusterName: string;
  vpcId: string;
  subnetIds: string[];
  idcInstanceARN: string;
  idcRegion: string;
  rbacRoleMappings: {
    role: string;
    identities: { id: string; type: string }[];
  }[];
  kubernetesVersion: string;
  accessEntries?: {
    principalArn: string;
    accessPolicy: string;
  }[];
}

export class MgmtClusterStack extends cdk.Stack {
  public readonly repo: codecommit.Repository;

  constructor(scope: Construct, id: string, props: MgmtClusterStackProps) {
    super(scope, id, props);

    // ── CodeCommit repository ──
    this.repo = new codecommit.Repository(this, "Repo", {
      repositoryName: props.clusterName,
      description: "EKS Hybrid Nodes bare metal provisioning",
    });

    // ── Capabilities trust policy ──
    const capabilitiesPrincipal = new iam.ServicePrincipal(
      "capabilities.eks.amazonaws.com"
    );

    // ── ArgoCD capability role ──
    const argoCDRole = new iam.Role(this, "ArgoCDCapabilityRole", {
      roleName: `AmazonEKSCapabilityArgoCDRole-${props.clusterName}`,
      assumedBy: capabilitiesPrincipal,
      description: `ArgoCD capability role for ${props.clusterName}`,
    });
    argoCDRole.assumeRolePolicy!.addStatements(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        principals: [capabilitiesPrincipal],
        actions: ["sts:TagSession"],
      })
    );
    argoCDRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName("AWSCodeCommitReadOnly")
    );
    argoCDRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName(
        "AWSSecretsManagerClientReadOnlyAccess"
      )
    );
    argoCDRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ["sso:DescribeInstance"],
        resources: ["*"],
      })
    );

    // ── ACK capability role ──
    const ackRole = new iam.Role(this, "ACKCapabilityRole", {
      roleName: `AmazonEKSCapabilityACKRole-${props.clusterName}`,
      assumedBy: capabilitiesPrincipal,
      description: `ACK capability role for ${props.clusterName}`,
    });
    ackRole.assumeRolePolicy!.addStatements(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        principals: [capabilitiesPrincipal],
        actions: ["sts:TagSession"],
      })
    );
    ackRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName("AdministratorAccess")
    );

    // ── EKS cluster role ──
    const clusterRole = new iam.Role(this, "ClusterRole", {
      roleName: `${props.clusterName}-cluster-role`,
      assumedBy: new iam.ServicePrincipal("eks.amazonaws.com"),
    });
    clusterRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonEKSClusterPolicy")
    );

    // ── EKS Cluster ──
    const cluster = new eks.CfnCluster(this, "Cluster", {
      name: props.clusterName,
      version: props.kubernetesVersion,
      roleArn: clusterRole.roleArn,
      resourcesVpcConfig: {
        subnetIds: props.subnetIds,
        endpointPrivateAccess: true,
        endpointPublicAccess: true,
      },
      accessConfig: {
        authenticationMode: "API",
      },
    });

    // ── ArgoCD cluster-admin access ──
    const accessEntry = new eks.CfnAccessEntry(this, "ArgoCDAccessEntry", {
      clusterName: props.clusterName,
      principalArn: argoCDRole.roleArn,
      type: "STANDARD",
      accessPolicies: [
        {
          policyArn:
            "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy",
          accessScope: { type: "cluster" },
        },
      ],
    });
    accessEntry.addDependency(cluster);

    // ── Additional IAM access entries ──
    for (const [i, entry] of (props.accessEntries ?? []).entries()) {
      const ae = new eks.CfnAccessEntry(this, `AccessEntry${i}`, {
        clusterName: props.clusterName,
        principalArn: entry.principalArn,
        type: "STANDARD",
        accessPolicies: [
          {
            policyArn: `arn:aws:eks::aws:cluster-access-policy/${entry.accessPolicy}`,
            accessScope: { type: "cluster" },
          },
        ],
      });
      ae.addDependency(cluster);
    }

    // ── Capabilities ──
    const argoCDCapability = new eks.CfnCapability(
      this,
      "ArgoCDCapability",
      {
        clusterName: props.clusterName,
        capabilityName: `${props.clusterName}-argocd`,
        type: "ARGOCD",
        roleArn: argoCDRole.roleArn,
        deletePropagationPolicy: "RETAIN",
        configuration: {
          argoCd: {
            namespace: "argocd",
            awsIdc: {
              idcInstanceArn: props.idcInstanceARN,
              idcRegion: props.idcRegion,
            },
            rbacRoleMappings: props.rbacRoleMappings,
          },
        },
      }
    );
    argoCDCapability.addDependency(cluster);

    const ackCapability = new eks.CfnCapability(this, "ACKCapability", {
      clusterName: props.clusterName,
      capabilityName: `${props.clusterName}-ack`,
      type: "ACK",
      roleArn: ackRole.roleArn,
      deletePropagationPolicy: "RETAIN",
    });
    ackCapability.addDependency(cluster);

    const kroCapability = new eks.CfnCapability(this, "KROCapability", {
      clusterName: props.clusterName,
      capabilityName: `${props.clusterName}-kro`,
      type: "KRO",
      roleArn: ackRole.roleArn,
      deletePropagationPolicy: "RETAIN",
    });
    kroCapability.addDependency(cluster);

    // ── Outputs for chart/values.yaml ──
    const clusterArn = `arn:aws:eks:${this.region}:${this.account}:cluster/${props.clusterName}`;
    new cdk.CfnOutput(this, "ClusterName", { value: props.clusterName });
    new cdk.CfnOutput(this, "ClusterARN", { value: clusterArn });
    new cdk.CfnOutput(this, "ArgoCDCapabilityRoleARN", {
      value: argoCDRole.roleArn,
    });
    new cdk.CfnOutput(this, "ACKCapabilityRoleARN", {
      value: ackRole.roleArn,
    });
    new cdk.CfnOutput(this, "KROSessionARN", {
      value: `arn:aws:sts::${this.account}:assumed-role/${ackRole.roleName}/KRO`,
      description: "kro assumed-role session ARN — use as mgmtCluster.kroRoleSessionARN",
    });
    new cdk.CfnOutput(this, "CodeCommitRepoURL", {
      value: this.repo.repositoryCloneUrlHttp,
    });
    new cdk.CfnOutput(this, "Region", { value: this.region });
    new cdk.CfnOutput(this, "AccountId", { value: this.account });
    new cdk.CfnOutput(this, "VpcId", { value: props.vpcId });
    new cdk.CfnOutput(this, "Subnets", {
      value: props.subnetIds.join(","),
    });
    new cdk.CfnOutput(this, "BootstrapCommand", {
      value: [
        `aws eks update-kubeconfig --name ${props.clusterName} --region ${this.region}`,
        `&& helm template ${props.clusterName} charts/mgmt-bootstrap/ -f values.yaml | kubectl apply -f -`,
      ].join(" "),
      description: "Run this after cdk deploy to bootstrap ArgoCD",
    });
  }
}
