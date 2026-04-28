#!/bin/bash
# Build an EKS Hybrid Nodes OS image from a cloud image.
# Input: cloud image (qcow2) → customize → convert to tar.gz filesystem archive
# Output: <name>.tar.gz + <name>.tar.gz.sha256
set -eo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
step() { echo; log "── $* ──"; STEP_START=$SECONDS; }
step_done() { log "   Done ($(( SECONDS - STEP_START ))s)"; }

: "${OS:?OS is required (e.g. ubuntu24)}"
: "${K8S_VERSION:?K8S_VERSION is required (e.g. 1.35)}"
: "${CREDENTIAL_PROVIDER:=ssm}"
: "${NODEADM_ARCH:=amd}"
: "${EXTRA_PACKAGES:=}"
: "${OUTPUT_DIR:=output}"

ARCH="amd64"
[ "$NODEADM_ARCH" = "arm" ] && ARCH="arm64"
IMAGE_TAG=$(echo "$IMAGE_URL" | grep -oP '/\K\d{8}(?=/)')
BUILD_TS=$(date -u +%Y%m%d%H%M)
NAME="${OS}-eks-${K8S_VERSION}-${ARCH}-${IMAGE_TAG}-${BUILD_TS}"
BUILD_START=$SECONDS

log "=== Building $NAME ==="
log "OS=$OS  K8S_VERSION=$K8S_VERSION  ARCH=$ARCH"
log "CREDENTIAL_PROVIDER=$CREDENTIAL_PROVIDER"
log "IMAGE_URL=$IMAGE_URL"
log "EXTRA_PACKAGES=$EXTRA_PACKAGES"

# ── Download ──
step "Downloading cloud image"
mkdir -p "$OUTPUT_DIR"
IMG="$OUTPUT_DIR/source.img"
curl -fSL -o "$IMG" "$IMAGE_URL"
log "   Size: $(du -h "$IMG" | cut -f1)"
step_done

# ── Verify ──
step "Verifying checksum"
echo "$IMAGE_CHECKSUM" | sed 's/^sha256://' | awk -v f="$IMG" '{print $1 "  " f}' | sha256sum -c -
step_done

# ── Expand disk ──
step "Expanding guest disk to 10G"
qemu-img resize "$IMG" 10G
virt-customize -a "$IMG" --run-command "growpart /dev/sda 1 && resize2fs /dev/sda1"
step_done

# ── Upgrade guest packages ──
step "Upgrading guest packages"
# TODO: re-enable full upgrade once build time is acceptable (~10-20 min overhead)
virt-customize -a "$IMG" --run-command "apt-get update -q"
# virt-customize -a "$IMG" --run-command "apt-get upgrade -q -y"
step_done

# ── Detect kernel version (post-upgrade) ──
step "Detecting kernel version"
KERNEL_VERSION=$(virt-ls -a "$IMG" /boot/ | grep -oP 'vmlinuz-\K\d+\.\d+\.\d+-\d+-generic' | sort -V | tail -1)
log "   Kernel: $KERNEL_VERSION"
step_done

# ── Build customization args ──
CUSTOMIZE_ARGS=(-a "$IMG"
  --run-command "apt-get install -q -y linux-modules-extra-${KERNEL_VERSION}"
)

case "$OS" in
  ubuntu24)
    log "   Ubuntu 24.04: adding containerd (AppArmor fix LP#2065423)"
    CUSTOMIZE_ARGS+=(--run-command "apt-get install -q -y containerd")
    CONTAINERD_SOURCE="distro"
    ;;
  ubuntu*)
    CONTAINERD_SOURCE="distro"
    ;;
  rhel*)
    CONTAINERD_SOURCE="docker"
    if [ -n "${RH_USERNAME:-}" ]; then
      log "   RHEL: registering with subscription manager"
      CUSTOMIZE_ARGS+=(--run-command "subscription-manager register --username='$RH_USERNAME' --password='$RH_PASSWORD' --auto-attach")
    fi
    ;;
esac

if [ -n "$EXTRA_PACKAGES" ]; then
  log "   Extra packages: $EXTRA_PACKAGES"
  CUSTOMIZE_ARGS+=(--run-command "apt-get install -q -y $EXTRA_PACKAGES")
fi

# Tuning packages (tuned, numactl, cpupower)
log "   Tuning packages: tuned numactl linux-tools-${KERNEL_VERSION}"
CUSTOMIZE_ARGS+=(--run-command "apt-get install -q -y tuned numactl linux-tools-${KERNEL_VERSION}")

CUSTOMIZE_ARGS+=(
  --run-command "curl -fSL -o /tmp/amazon-ssm-agent.deb https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_${ARCH}/amazon-ssm-agent.deb && dpkg -i /tmp/amazon-ssm-agent.deb && rm /tmp/amazon-ssm-agent.deb"
  --run-command "printf '[Unit]\nDescription=amazon-ssm-agent (snap compat)\n[Service]\nType=simple\nExecStart=/usr/bin/amazon-ssm-agent\nRestart=always\nRestartSec=90\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/snap.amazon-ssm-agent.amazon-ssm-agent.service"
  --run-command "systemctl enable amazon-ssm-agent snap.amazon-ssm-agent.amazon-ssm-agent"
  --run-command "curl -fSL -o /usr/local/bin/nodeadm https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/${ARCH}/nodeadm"
  --run-command "chmod +x /usr/local/bin/nodeadm"
  --run-command "/usr/local/bin/nodeadm install $K8S_VERSION --credential-provider $CREDENTIAL_PROVIDER --containerd-source $CONTAINERD_SOURCE"
)

if [[ "$OS" == rhel* ]] && [ -n "${RH_USERNAME:-}" ]; then
  CUSTOMIZE_ARGS+=(--run-command "subscription-manager unregister || true")
fi

CUSTOMIZE_ARGS+=(
  --run-command "cloud-init clean --logs --seed"
  --run-command "rm -f /var/log/*.log"
)

# ── Customize ──
step "Customizing image with virt-customize"
log "   Packages: linux-modules-extra-generic, containerd, nodeadm"
log "   nodeadm install $K8S_VERSION --credential-provider $CREDENTIAL_PROVIDER --containerd-source $CONTAINERD_SOURCE"
virt-customize "${CUSTOMIZE_ARGS[@]}"
step_done

# ── Create archive ──
step "Creating filesystem archive"
MOUNT=$(mktemp -d)
log "   Mounting image at $MOUNT"
guestmount -a "$IMG" -i "$MOUNT"

ARCHIVE="$OUTPUT_DIR/${NAME}.tar.gz"
log "   Tarring filesystem to $ARCHIVE"
tar czf "$ARCHIVE" -C "$MOUNT" --exclude='./lost+found' .

log "   Unmounting"
guestunmount "$MOUNT"
rmdir "$MOUNT"
rm "$IMG"
step_done

# ── Checksum ──
step "Generating checksum"
sha256sum "$ARCHIVE" | awk '{print "sha256:" $1}' > "${ARCHIVE}.sha256"
step_done

# ── Summary ──
echo
log "=== Build complete ($(( SECONDS - BUILD_START ))s total) ==="
log "Archive:  $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
log "Checksum: $(cat ${ARCHIVE}.sha256)"
