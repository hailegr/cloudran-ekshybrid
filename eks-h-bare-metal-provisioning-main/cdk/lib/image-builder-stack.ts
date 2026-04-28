import * as cdk from "aws-cdk-lib";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as codebuild from "aws-cdk-lib/aws-codebuild";
import * as codecommit from "aws-cdk-lib/aws-codecommit";
import { Construct } from "constructs";

export interface ImageBuilderStackProps extends cdk.StackProps {
  repo: codecommit.IRepository;
}

export class ImageBuilderStack extends cdk.Stack {
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: ImageBuilderStackProps) {
    super(scope, id, props);

    // ── S3 bucket for OS images ──
    this.bucket = new s3.Bucket(this, "ImageBucket", {
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [
        {
          noncurrentVersionExpiration: cdk.Duration.days(30),
        },
      ],
    });

    // ── CodeBuild project ──
    const project = new codebuild.Project(this, "ImageBuilder", {
      description: "Build OS images for EKS Hybrid Nodes bare metal provisioning",
      source: codebuild.Source.codeCommit({ repository: props.repo }),
      environment: {
        buildImage: codebuild.LinuxBuildImage.STANDARD_7_0,
        computeType: codebuild.ComputeType.X2_LARGE,
        privileged: true, // required for libguestfs/QEMU
      },
      buildSpec: codebuild.BuildSpec.fromSourceFilename(
        "image-builder/os-image-buildspec.yml"
      ),
      environmentVariables: {
        IMAGE_BUCKET: { value: this.bucket.bucketName },
      },
      timeout: cdk.Duration.hours(2),
    });

    // Grant CodeBuild access to S3
    this.bucket.grantReadWrite(project);

    // ── Outputs ──
    new cdk.CfnOutput(this, "ImageBucketName", {
      value: this.bucket.bucketName,
      description: "S3 bucket for OS images",
    });
    new cdk.CfnOutput(this, "CodeBuildProject", {
      value: project.projectName,
      description: "CodeBuild project for image builds",
    });
    new cdk.CfnOutput(this, "BuildCommand", {
      value: [
        `aws codebuild start-build`,
        `--project-name ${project.projectName}`,
        `--environment-variables-override name=OS,value=ubuntu24 name=K8S_VERSION,value=1.35`,
        `--region ${this.region}`,
      ].join(" "),
      description: "Example command to trigger an image build",
    });
  }
}
