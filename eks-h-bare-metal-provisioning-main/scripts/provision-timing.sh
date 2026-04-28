#!/bin/bash
# Usage: ./scripts/provision-timing.sh <server-name> [namespace]
# Shows workflow action timings and waits for the node to join.
set -eo pipefail

SERVER=${1:?Usage: $0 <server-name> [namespace]}
NS=${2:-tinkerbell}

# Find the latest workflow for this server
find_workflow() {
  kubectl get workflows -n "$NS" --no-headers -l "hardware=$SERVER" -o name 2>/dev/null | tail -1 | sed 's|.*/||'
}

echo "=== Provisioning timeline for ${SERVER} ==="
printf "Waiting for workflow..."
until WF=$(find_workflow) && [ -n "$WF" ]; do
  printf "."
  sleep 5
done
echo " found: $WF"
echo

# Poll until workflow reaches a terminal state
PREV=""
while true; do
  OUT=$(kubectl get workflow "$WF" -n "$NS" -o json 2>/dev/null | python3 -c "
import sys,json
w=json.load(sys.stdin)
s=w.get('status',{})
state=s.get('state','')
actions=[]
for t in s.get('tasks',[]):
    for a in t.get('actions',[]):
        d=a.get('executionDuration','')
        # convert to seconds
        secs=0
        import re
        for m in re.finditer(r'(\d+)h',d): secs+=int(m.group(1))*3600
        for m in re.finditer(r'(\d+)m(?!s)',d): secs+=int(m.group(1))*60
        for m in re.finditer(r'(\d+)s(?!$|[a-z])',d): secs+=int(m.group(1))
        for m in re.finditer(r'(\d+)s$',d): secs+=int(m.group(1))
        for m in re.finditer(r'(\d+)ms',d): secs+=int(m.group(1))/1000
        for m in re.finditer(r'(\d+)us',d): secs+=int(m.group(1))/1000000
        ds=f'{secs:.1f}s' if d else ''
        actions.append((a.get('name',''),ds,a.get('state','')))
print(state)
for n,d,s in actions:
    print(f'{n}\t{d}\t{s}')
" 2>/dev/null)

  STATE=$(echo "$OUT" | head -1)
  BODY=$(echo "$OUT" | tail -n+2)

  if [ -n "$BODY" ] && [ "$BODY" != "$PREV" ]; then
    echo "Action                              Duration  Status"
    echo "──────────────────────────────────  --------  -------"
    echo "$BODY" | while IFS=$'\t' read -r name dur status; do
      printf "%-34s  %7s  %s\n" "$name" "$dur" "$status"
    done
    echo
    PREV="$BODY"
  fi

  case "$STATE" in
    SUCCESS)
      echo "✅ Workflow completed successfully"
      break ;;
    FAILED)
      echo "❌ Workflow failed"
      exit 1 ;;
    TIMEOUT)
      echo "⏰ Workflow timed out"
      exit 1 ;;
  esac
  sleep 10
done

# Timestamps
WF_CREATED=$(kubectl get workflow "$WF" -n "$NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
WF_EPOCH=$(date -d "$WF_CREATED" +%s 2>/dev/null)
echo
echo "Workflow created: $WF_CREATED"

# Wait for node to appear and become Ready
echo
printf "Waiting for node ${SERVER} to join and become Ready..."
while true; do
  # Find hybrid nodes (compute-type=hybrid) created after the workflow
  NODE=$(kubectl get nodes -l "eks.amazonaws.com/compute-type=hybrid" --no-headers -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp' 2>/dev/null | while read -r name ts; do
    ts_epoch=$(date -d "$ts" +%s 2>/dev/null)
    if [ "$ts_epoch" -ge "$WF_EPOCH" ] 2>/dev/null; then
      echo "$name"
    fi
  done | head -1)
  if [ -n "$NODE" ]; then
    STATUS=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$STATUS" = "True" ]; then break; fi
  fi
  printf "."
  sleep 10
done
echo " joined as $NODE"

NODE_JOINED=$(kubectl get node "$NODE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
NODE_READY=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}' 2>/dev/null)

WF_EPOCH=$(date -d "$WF_CREATED" +%s 2>/dev/null)
JOIN_EPOCH=$(date -d "$NODE_JOINED" +%s 2>/dev/null)
READY_EPOCH=$(date -d "$NODE_READY" +%s 2>/dev/null)

echo
echo "Timeline:"
echo "──────────────────────────────────────────────────────"
printf "  %-25s %s\n" "Workflow created:" "$WF_CREATED"
printf "  %-25s %s\n" "Node registered:" "$NODE_JOINED"
printf "  %-25s %s\n" "Node Ready:" "$NODE_READY"
echo
printf "  %-40s %ss\n" "Workflow → node registered:" "$(( JOIN_EPOCH - WF_EPOCH ))"
printf "  %-40s %ss\n" "Node registered → Ready:" "$(( READY_EPOCH - JOIN_EPOCH ))"
printf "  %-40s %ss\n" "Total (workflow created → node Ready):" "$(( READY_EPOCH - WF_EPOCH ))"
echo

kubectl get node "$NODE" -o wide 2>/dev/null
echo
echo "Labels:"
kubectl get node "$NODE" -o jsonpath='{.metadata.labels}' 2>/dev/null | python3 -c "
import sys,json
for k,v in sorted(json.load(sys.stdin).items()):
    if any(x in k for x in ['hostname','compute-type','instance-type','topology','role']):
        print(f'  {k}={v}')
" 2>/dev/null
