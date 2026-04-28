#!/bin/bash
# SSM activation creator for EKS Hybrid Nodes bare metal provisioning.
# Runs as a kro-managed Job. All inputs come from environment variables
# set by the kro RGD template.
#
# Required env: MACHINE_NAME, NAMESPACE, ROLE_NAME, CLUSTER_NAME, CLUSTER_REGION, MACHINE_PROFILE
# Optional env: TUNING_SYSCTL, TUNING_DISABLED_SERVICES
set -eo pipefail

# --- Install kubectl (with checksum verification) ---
K8S_VERSION="$(curl -sL https://dl.k8s.io/release/stable.txt)"
curl -sLO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
curl -sLO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
chmod +x kubectl && mv kubectl /usr/local/bin/
rm -f kubectl.sha256

# --- Clean up exhausted/expired activations ---
EXISTING_ID=$(kubectl get secret "$MACHINE_NAME-ssm" -n "$NAMESPACE" -o jsonpath='{.data.activationId}' 2>/dev/null | base64 -d || true)
if [ -n "$EXISTING_ID" ]; then
  EXPIRED=$(aws ssm describe-activations --region "$CLUSTER_REGION" \
    --filters "FilterKey=ActivationIds,FilterValues=$EXISTING_ID" \
    --query 'ActivationList[0].Expired' --output text 2>/dev/null || echo "true")
  REG_COUNT=$(aws ssm describe-activations --region "$CLUSTER_REGION" \
    --filters "FilterKey=ActivationIds,FilterValues=$EXISTING_ID" \
    --query 'ActivationList[0].RegistrationsCount' --output text 2>/dev/null || echo "1")
  REG_LIMIT=$(aws ssm describe-activations --region "$CLUSTER_REGION" \
    --filters "FilterKey=ActivationIds,FilterValues=$EXISTING_ID" \
    --query 'ActivationList[0].RegistrationLimit' --output text 2>/dev/null || echo "1")
  if { [ "$EXPIRED" = "False" ] || [ "$EXPIRED" = "false" ]; } && [ "$REG_COUNT" -lt "$REG_LIMIT" ]; then
    echo "Valid activation $EXISTING_ID exists (used $REG_COUNT/$REG_LIMIT)"
    HAS_USERDATA=$(kubectl get configmap "$MACHINE_NAME-ssm" -n "$NAMESPACE" -o jsonpath='{.data.userData}' 2>/dev/null || true)
    if [ -n "$HAS_USERDATA" ]; then
      echo "ConfigMap already has userData, patching Hardware and skipping"
      PATCH_JSON=$(kubectl get configmap "$MACHINE_NAME-ssm" -n "$NAMESPACE" -o jsonpath='{.data.userData}' | \
        jq -Rs '{spec: {userData: .}}')
      kubectl patch hardware "$MACHINE_NAME" -n "$NAMESPACE" --type=merge -p "$PATCH_JSON"
      exit 0
    fi
  fi
  echo "Cleaning up old activation $EXISTING_ID (used $REG_COUNT/$REG_LIMIT, expired=$EXPIRED)"
  aws ssm delete-activation --activation-id "$EXISTING_ID" --region "$CLUSTER_REGION" 2>/dev/null || true
fi

# --- Create new SSM activation ---
EXPIRY=$(date -u -d "+2 hours" +%Y-%m-%dT%H:%M:%SZ)
ACTIVATION=$(aws ssm create-activation \
  --default-instance-name "$MACHINE_NAME" \
  --description "EKS hybrid node: $MACHINE_NAME" \
  --iam-role "$ROLE_NAME" \
  --registration-limit 1 \
  --expiration-date "$EXPIRY" \
  --region "$CLUSTER_REGION" \
  --output json)

ID=$(echo "$ACTIVATION" | python3 -c "import sys,json; print(json.load(sys.stdin)['ActivationId'])")
CODE=$(echo "$ACTIVATION" | python3 -c "import sys,json; print(json.load(sys.stdin)['ActivationCode'])")

# --- Generate cloud-init userdata ---
read -r -d '' USERDATA <<'CLOUD_CONFIG' || true
#cloud-config
write_files:
  - path: /etc/eks/nodeadm-config.yaml
    owner: root:root
    permissions: '0644'
    content: |
      apiVersion: node.eks.aws/v1alpha1
      kind: NodeConfig
      spec:
        cluster:
          name: __CLUSTER_NAME__
          region: __CLUSTER_REGION__
        kubelet:
          flags:
            - --node-labels=node.kubernetes.io/hostname=__MACHINE_NAME__,node.eks.aws/machine-profile=__MACHINE_PROFILE__
        hybrid:
          enableCredentialsFile: true
          ssm:
            activationCode: __CODE__
            activationId: __ID__
  - path: /opt/eks/join-node.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      nodeadm init -c file:///etc/eks/nodeadm-config.yaml
runcmd:
  - [bash, /opt/eks/join-node.sh]
CLOUD_CONFIG

# Substitute placeholders with actual values
USERDATA="${USERDATA//__CLUSTER_NAME__/$CLUSTER_NAME}"
USERDATA="${USERDATA//__CLUSTER_REGION__/$CLUSTER_REGION}"
USERDATA="${USERDATA//__MACHINE_NAME__/$MACHINE_NAME}"
USERDATA="${USERDATA//__MACHINE_PROFILE__/$MACHINE_PROFILE}"
USERDATA="${USERDATA//__CODE__/$CODE}"
USERDATA="${USERDATA//__ID__/$ID}"

# --- Inject tuning runcmd entries before join-node ---
TUNING_RUNCMD=""
if [ -n "$TUNING_SYSCTL" ]; then
  TUNING_RUNCMD+="  - [sysctl, --system]\n"
fi
if [ -n "$TUNING_DISABLED_SERVICES" ]; then
  IFS=',' read -ra SVCS <<< "$TUNING_DISABLED_SERVICES"
  for svc in "${SVCS[@]}"; do
    TUNING_RUNCMD+="  - [systemctl, disable, --now, $svc]\n"
  done
fi
if [ -n "$TUNING_RUNCMD" ]; then
  TUNING_LINES=$(printf '%b' "$TUNING_RUNCMD")
  USERDATA=$(awk -v insert="$TUNING_LINES" '/- \[bash, \/opt\/eks\/join-node.sh\]/{print insert}1' <<< "$USERDATA")
fi

# --- Write Secret and ConfigMap ---
kubectl create secret generic "$MACHINE_NAME-ssm" \
  --namespace "$NAMESPACE" \
  --from-literal=activationId="$ID" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap "$MACHINE_NAME-ssm" \
  --namespace "$NAMESPACE" \
  --from-literal=userData="$USERDATA" \
  --dry-run=client -o yaml | kubectl apply -f -

# Patch Hardware with userData so Tootles can serve it to the server at boot
PATCH_JSON=$(echo "$USERDATA" | jq -Rs '{spec: {userData: .}}')
kubectl patch hardware "$MACHINE_NAME" -n "$NAMESPACE" --type=merge -p "$PATCH_JSON"

echo "Done: $MACHINE_NAME (activation $ID, expires $EXPIRY)"
