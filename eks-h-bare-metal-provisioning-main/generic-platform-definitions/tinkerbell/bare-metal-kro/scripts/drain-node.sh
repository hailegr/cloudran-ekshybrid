#!/bin/bash
# Drain and delete a Kubernetes node during deprovisioning.
# Looks up the node by its GitOps label (node.kubernetes.io/hostname)
# since the actual K8s node name is SSM-generated (mi-xxxxx).
#
# Required env: MACHINE_NAME, PROVISION
set -eo pipefail

if [ "$PROVISION" = "true" ]; then
  echo "provision=true, skipping deprovision"
  exit 0
fi

echo "provision=false, deprovisioning node with label hostname=$MACHINE_NAME"

# Find the K8s node by its GitOps hostname label
K8S_NODE=$(kubectl get nodes -l "node.kubernetes.io/hostname=$MACHINE_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$K8S_NODE" ]; then
  echo "No node found with label node.kubernetes.io/hostname=$MACHINE_NAME, already removed"
  exit 0
fi

echo "Found K8s node: $K8S_NODE"

kubectl drain "$K8S_NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=30s \
  --force || true

kubectl delete node "$K8S_NODE" --wait=false
echo "Node $K8S_NODE drained and deleted"
