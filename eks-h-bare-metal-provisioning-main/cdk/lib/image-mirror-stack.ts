import * as cdk from "aws-cdk-lib";
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as codebuild from "aws-cdk-lib/aws-codebuild";
import * as iam from "aws-cdk-lib/aws-iam";
import * as codecommit from "aws-cdk-lib/aws-codecommit";
import * as fs from "fs";
import * as path from "path";
import * as YAML from "yaml";
import { Construct } from "constructs";

export interface ImageMirrorStackProps extends cdk.StackProps {
  repo: codecommit.IRepository;
  clusterName: string;
}

export class ImageMirrorStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: ImageMirrorStackProps) {
    super(scope, id, props);

    const prefix = props.clusterName;

    // ── Load mirror config ──
    const configPath = path.join(__dirname, "..", "..", "image-builder", "mirror-images.yaml");
    const config = YAML.parse(fs.readFileSync(configPath, "utf8"));
    const images: Record<string, { source: string; tags: string[] }> = config.images;

    // ── ECR repositories ──
    const repos: Record<string, ecr.Repository> = {};
    for (const name of Object.keys(images)) {
      repos[name] = new ecr.Repository(this, `Repo-${name.replace(/\//g, "-")}`, {
        repositoryName: `${prefix}/${name}`,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
        lifecycleRules: [{ maxImageCount: 50 }],
        imageScanOnPush: true,
      });
    }

    // ── CodeBuild project ──
    const project = new codebuild.Project(this, "ImageMirror", {
      description: "Mirror container images to ECR for air-gapped provisioning",
      source: codebuild.Source.codeCommit({ repository: props.repo }),
      environment: {
        buildImage: codebuild.LinuxBuildImage.STANDARD_7_0,
        computeType: codebuild.ComputeType.SMALL,
        privileged: true, // required for docker build
      },
      buildSpec: codebuild.BuildSpec.fromSourceFilename(
        "image-builder/mirror-buildspec.yml"
      ),
      environmentVariables: {
        AWS_ACCOUNT_ID: { value: this.account },
        AWS_DEFAULT_REGION: { value: this.region },
        ECR_PREFIX: { value: prefix },
      },
      timeout: cdk.Duration.minutes(30),
    });

    // Grant ECR push to all repos
    for (const repo of Object.values(repos)) {
      repo.grantPullPush(project);
    }

    // ECR auth token
    project.addToRolePolicy(new iam.PolicyStatement({
      actions: ["ecr:GetAuthorizationToken"],
      resources: ["*"],
    }));

    // ── Outputs ──
    const registryUri = `${this.account}.dkr.ecr.${this.region}.amazonaws.com`;
    new cdk.CfnOutput(this, "ECRRegistry", {
      value: registryUri,
      description: "ECR registry URI prefix for actionImages in values.yaml",
    });
    new cdk.CfnOutput(this, "MirrorProject", {
      value: project.projectName,
      description: "CodeBuild project to mirror images",
    });
    new cdk.CfnOutput(this, "MirrorCommand", {
      value: `aws codebuild start-build --project-name ${project.projectName} --region ${this.region}`,
      description: "Trigger image mirror",
    });

    // Output per-repo URIs for values.yaml actionImages
    for (const [name, repo] of Object.entries(repos)) {
      const outputName = "Repo" + name.replace(/[^A-Za-z0-9]/g, "");
      new cdk.CfnOutput(this, outputName, {
        value: repo.repositoryUri,
        description: `ECR URI for ${name}`,
      });
    }
  }
}
