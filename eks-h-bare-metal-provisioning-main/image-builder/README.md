# OS Image Build Pipeline

The platform includes a framework for building, storing, and serving OS images to bare metal servers during Tinkerbell provisioning. The CSE team provides this framework as a reference implementation. **The OS image is owned and operated by the customer** — the customer is responsible for the image content, patching cadence, vulnerability remediation, and compliance with their organizational security policies.

## Ownership Model

| # | Area | Owner | Responsibility |
|---|------|-------|----------------|
| 1 | Image build framework (scripts, buildspec, CDK stack) | AWS CSE | Provide and maintain the build tooling. Fix bugs, add OS support. |
| 2 | Source image selection (Ubuntu, RHEL, AL2023) | Customer / SI | Choose the base OS distribution and version. Validate licensing. |
| 3 | Image content (packages, kernel, security hardening) | Customer / SI | Customize the image to meet organizational security baselines. Add or remove packages. |
| 4 | Image build execution (triggering builds) | Customer / SI | Run builds on their schedule. Integrate into their patching cadence. |
| 5 | Image patching and CVE remediation | Customer / SI | Rebuild images when security patches are available. Scan for vulnerabilities. |
| 6 | Image storage (S3 bucket) | Customer | The S3 bucket is in the customer's AWS account. Customer controls access, retention, and encryption. |
| 7 | Image serving (image-server Deployment) | Platform (automated) | Runs in the workload cluster. Syncs from S3 automatically. |
| 8 | nodeadm and SSM agent versions | AWS (upstream) | Provided by AWS. Customer should pin and verify versions. |

The CSE team does not vend OS images to customers. The framework downloads official cloud images from upstream distribution mirrors (e.g., `cloud-images.ubuntu.com`) and customizes them with the components required for EKS Hybrid Nodes. The customer can modify every aspect of this process.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Image Build (CDK ImageBuilderStack)                                     │
│                                                                          │
│  ┌──────────────┐     ┌──────────────────────────────────────────────┐   │
│  │  CodeBuild   │────►│  os-image-buildspec.yml                      │   │
│  │  Project     │     │  1. Install libguestfs, QEMU                 │   │
│  │              │     │  2. Load config from images.yaml             │   │
│  │  Trigger:    │     │  3. Download cloud image (qcow2)             │   │
│  │  Manual or   │     │  4. Verify SHA256 checksum                   │   │
│  │  Pipeline    │     │  5. Customize: linux-modules-extra,          │   │
│  │              │     │     containerd, SSM agent, nodeadm           │   │
│  │              │     │  6. Create tar.gz filesystem archive         │   │
│  │              │     │  7. Upload tar.gz + sha256 to S3             │   │
│  └──────────────┘     └──────────────────────────────────────────────┘   │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  S3 Bucket (versioned, RETAIN, 30-day noncurrent expiry)           │ │
│  │  images/<os>-eks-<k8s_version>-<arch>.tar.gz                       │ │
│  │  images/<os>-eks-<k8s_version>-<arch>.tar.gz.sha256                │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              │ aws s3 sync (sidecar, every 5 min)
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Image Serving (per workload cluster)                                    │
│                                                                          │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────────────┐  │
│  │  Sidecar:    │────►│  PVC         │────►│  nginx                   │  │
│  │  aws s3 sync │     │  (os-images) │     │  Serves via internal NLB │  │
│  └──────────────┘     └──────────────┘     └──────────┬───────────────┘  │
│                                                       │                  │
│  Pod Identity: image-server SA → S3 read-only role     │                  │
└───────────────────────────────────────────────────────┼──────────────────┘
                                                       │
                                                       │ HTTP (internal NLB)
                                                       ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Bare Metal Server (Tinkerbell Workflow)                                  │
│                                                                          │
│  Workflow streams tar.gz from image-server NLB IP                        │
│  → partitions disk → extracts archive → writes cloud-init → boots OS     │
└──────────────────────────────────────────────────────────────────────────┘
```

## Supported Distributions

- Ubuntu 24.04 (Noble) — default
- Ubuntu 22.04 (Jammy) — add to `images.yaml`
- RHEL 8, 9 — add to `images.yaml`

## Build Process

**What CDK creates** (see `cdk/lib/image-builder-stack.ts`):
- An S3 bucket for OS images (versioned, S3-managed encryption, RETAIN on deletion, 30-day noncurrent version expiry)
- A CodeBuild project (privileged mode for libguestfs/QEMU, X2_LARGE compute, 2-hour timeout)
- IAM role granting CodeBuild read/write access to the S3 bucket

**Build steps** (executed by `os-image-build.sh`):
1. Downloads the cloud image (qcow2) from the URL pinned in `images.yaml`
2. Verifies the downloaded image against the SHA256 checksum pinned in `images.yaml`
3. Expands the guest disk to 10GB and resizes the root partition
4. Customizes the image with `virt-customize`:
   - Installs `linux-modules-extra` for the detected kernel version
   - Installs `containerd` (from distro packages for Ubuntu, Docker repo for RHEL)
   - Installs the AWS SSM agent (`.deb` from the official S3 endpoint)
   - Downloads and installs `nodeadm` from the EKS Hybrid Assets endpoint
   - Runs `nodeadm install <k8s_version>` to pre-configure the node join components
   - Cleans cloud-init state and logs
5. Mounts the image and creates a tar.gz filesystem archive
6. Generates a SHA256 checksum file
7. Uploads both to `s3://<bucket>/images/`

## Usage

```bash
# Default: Ubuntu 24.04 for EKS 1.35
aws codebuild start-build \
  --project-name <CodeBuildProject from CDK outputs> \
  --region <region>

# Override OS or K8s version
aws codebuild start-build \
  --project-name <CodeBuildProject from CDK outputs> \
  --environment-variables-override name=OS,value=ubuntu24 name=K8S_VERSION,value=1.36 \
  --region <region>
```

Environment variable overrides: `OS` (default: `ubuntu24`), `K8S_VERSION` (default: `1.35`), `CREDENTIAL_PROVIDER` (default: `ssm`), `NODEADM_ARCH` (default: `amd`), `EXTRA_PACKAGES` (optional).

## Output

```
s3://<bucket>/images/<os>-eks-<k8s_version>-amd64.tar.gz
s3://<bucket>/images/<os>-eks-<k8s_version>-amd64.tar.gz.sha256
```

## Configuration

Image URLs and checksums are pinned in `images.yaml`. This file is the source of truth for reproducible builds. Update it to change the source image or add new distributions.

## Image Serving

Each workload cluster runs an `image-server` Deployment in the `tinkerbell` namespace:
- A sidecar container runs `aws s3 sync` every 5 minutes to pull `.tar.gz` and `.sha256` files from the S3 bucket to a PVC
- An nginx container serves the PVC contents over HTTP via an internal NLB
- Pod Identity maps the `image-server` ServiceAccount to an IAM role with S3 read access scoped to the image bucket
- Tinkerbell Workflows reference the image-server NLB IP (resolved by the endpoint-sync Job) to stream the archive during provisioning

**osProfiles** in `values.yaml` link the Tinkerbell Template to a specific archive filename and checksum:
```yaml
osProfiles:
  ubuntu-noble:
    archive: ubuntu24-eks-1.35-amd64.tar.gz
    archiveChecksum: "sha256:..."  # set after image build
    kernelPath: /boot/vmlinuz
    initrdPath: /boot/initrd.img
```

## Image Security and Integrity

The current implementation provides baseline integrity controls. The customer is expected to layer additional security measures appropriate to their environment.

**Current controls:**

| # | Control | Description |
|---|---------|-------------|
| 1 | Source image checksum verification | `os-image-build.sh` verifies the downloaded cloud image SHA256 against the checksum pinned in `images.yaml`. Build fails if the checksum does not match. |
| 2 | S3 bucket versioning | All image uploads are versioned. Previous versions are retained for 30 days, enabling rollback. |
| 3 | S3-managed encryption | Images are encrypted at rest with S3-managed keys (SSE-S3). |
| 4 | Output checksum | A SHA256 checksum file is generated and uploaded alongside each archive. The osProfile references this checksum. |
| 5 | RETAIN deletion policy | The S3 bucket is not deleted when the CDK stack is destroyed, preventing accidental image loss. |
| 6 | Pod Identity scoping | The image-server IAM role is scoped to read-only access on the specific image bucket. |

**Planned security enhancements (not yet implemented):**

| # | Enhancement | Description |
|---|-------------|-------------|
| 1 | Output signing | Sign tar.gz archives with AWS Signer or `cosign`. Image-server verifies signature before serving. |
| 2 | S3 Object Lock | Enable WORM (Write Once Read Many) on the `images/` prefix to prevent overwrites and deletes. |
| 3 | S3 write restriction | Separate IAM roles: CodeBuild gets `s3:PutObject` only, image-server gets read-only. No principal has `s3:DeleteObject`. |
| 4 | Build environment isolation | Run CodeBuild in a VPC with egress restricted to allowlisted endpoints (Ubuntu archive, AWS endpoints, RHEL CDN). |
| 5 | SBOM generation | Run `syft` or dump `dpkg --list` during build. Store the software bill of materials alongside the archive in S3. |
| 6 | Vulnerability scanning | Run `grype` or Amazon Inspector on the output image. Fail the build on critical CVEs. |
| 7 | SLSA provenance attestation | Use `cosign attest` to record the source commit → build → artifact chain for supply chain integrity. |
| 8 | Pin nodeadm checksum | Verify the nodeadm binary SHA256 after download (pending AWS publishing checksums per version). |
| 9 | CodePipeline approval gate | Wrap the CodeBuild project in a CodePipeline with a manual approval step before publishing to S3. |

**Customer responsibilities for image security:**
- Establish a patching cadence: rebuild images regularly to incorporate upstream security patches
- Run vulnerability scanning on built images before deploying to production
- Apply organizational security baselines (CIS benchmarks, STIG profiles, etc.) by customizing `os-image-build.sh`
- Manage S3 bucket policies, KMS encryption keys, and access controls according to their security requirements
- Monitor for CVEs in the installed components (kernel, containerd, SSM agent, nodeadm) and trigger rebuilds as needed
- Consider enabling S3 Object Lock and output signing for production deployments

## Image Lifecycle Operations

**Building a new image version:**
1. (Optional) Update `images.yaml` if changing the source image or checksum
2. Trigger a CodeBuild build with the desired `OS` and `K8S_VERSION`
3. After build completes, note the output checksum from the build logs
4. Update the `archiveChecksum` in the osProfile in `values.yaml`
5. Commit and push — new server provisioning uses the updated image. Existing servers are not affected.

**Rolling out a new image to existing servers:**
1. Build and publish the new image (steps above)
2. For each server that needs the update: delete its Workflow (`kubectl delete workflow provision-<server> -n tinkerbell`)
3. kro recreates the Workflow, Tinkerbell re-provisions the server with the new image
4. This is a rolling operation — re-provision servers one at a time or in batches to maintain availability

**Adding a new OS distribution:**
1. Add the distribution entry to `images.yaml` with the source image URL and checksum
2. If needed, add OS-specific customization logic to `os-image-build.sh` (see the existing `ubuntu24` and `rhel*` cases)
3. Add a corresponding osProfile to `values.yaml`
4. Trigger a build and verify the output

## Local Build

```bash
export OS=ubuntu24 K8S_VERSION=1.35
python3 load-config.py
export $(cat /tmp/image-config.env | xargs)
bash os-image-build.sh
```
