#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import * as fs from "fs";
import * as path from "path";
import * as YAML from "yaml";
import { MgmtClusterStack } from "../lib/mgmt-cluster-stack";
import { ImageBuilderStack } from "../lib/image-builder-stack";
import { ImageMirrorStack } from "../lib/image-mirror-stack";

const app = new cdk.App();

// Load config from config.yaml (copy from config.example.yaml)
const configPath = path.join(__dirname, "..", "config.yaml");
if (!fs.existsSync(configPath)) {
  throw new Error("config.yaml not found. Copy config.example.yaml to config.yaml and fill in your values.");
}
const config = YAML.parse(fs.readFileSync(configPath, "utf8"));

const required = ["clusterName", "vpcId", "subnetIds", "idcInstanceARN", "rbacRoleMappings"];
for (const key of required) {
  if (!config[key]) {
    throw new Error(`Missing required field '${key}' in config.yaml`);
  }
}

const mgmt = new MgmtClusterStack(app, `${config.clusterName}-mgmt`, {
  clusterName: config.clusterName,
  vpcId: config.vpcId,
  subnetIds: config.subnetIds,
  idcInstanceARN: config.idcInstanceARN,
  idcRegion: config.idcRegion ?? "us-east-1",
  rbacRoleMappings: config.rbacRoleMappings,
  kubernetesVersion: config.kubernetesVersion ?? "1.35",
  accessEntries: config.accessEntries ?? [],
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: config.region ?? process.env.CDK_DEFAULT_REGION,
  },
});

new ImageBuilderStack(app, `${config.clusterName}-image-builder`, {
  repo: mgmt.repo,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: config.region ?? process.env.CDK_DEFAULT_REGION,
  },
});

new ImageMirrorStack(app, `${config.clusterName}-image-mirror`, {
  repo: mgmt.repo,
  clusterName: config.clusterName,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: config.region ?? process.env.CDK_DEFAULT_REGION,
  },
});
