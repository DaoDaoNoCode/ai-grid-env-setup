#!/usr/bin/env bash
# Adds or removes a GPU or CPU worker MachineSet on one spoke, against the spoke's own kubeconfig
# ($KUBEDIR/<spoke>), by cloning one of its existing worker MachineSets (AMI, subnet, security groups,
# IAM profile and volume carry over):
#   bash hack/spoke-machineset.sh gpu|cpu apply|delete <spoke> [--dry-run]
# GPU_INSTANCE_TYPE (g6.xlarge), GPU_REPLICAS (1), GPU_AZ (the cloned MachineSet's zone), GPU_VOLUME_SIZE (120),
# CPU_INSTANCE_TYPE (m6a.4xlarge), CPU_REPLICAS (1), CPU_AZ, CPU_VOLUME_SIZE (120), DRY_RUN=1.
# Rerun-safe, but stops while machines of another type or volume size exist. Waits for the node, and stops with the Machine's own error when AWS refuses it
# (InsufficientInstanceCapacity, an unsupported type): retry with GPU_AZ=<other zone> or a smaller type.
# Ported from rh-aiservices-bu/rhoai-nightly f166a47 (scripts/create-gpu-machineset.sh and
# create-cpu-machineset.sh, with their templates; Chris Chase wrote them). Differences: it clones a
# MachineSet instead of filling a template, takes the spoke by kubeconfig, and creates no
# ClusterAutoscaler or MachineAutoscaler (replicas stay where you set them).
source "$(dirname "$0")/../bootstrap/lib.sh"
kind=${1:?usage: spoke-machineset.sh gpu|cpu apply|delete <spoke> [--dry-run]} action=${2:?apply or delete} spoke=${3:?spoke name}
dry=${DRY_RUN:-}; [[ ${4:-} == --dry-run ]] && dry=1
[[ $kind == gpu || $kind == cpu ]] || die "kind is gpu or cpu"
[[ -f $(kcfg "$spoke") ]] || die "no kubeconfig for $spoke: expected $(kcfg "$spoke")"
ns=openshift-machine-api
mark=ai-grid/spoke-infra
platform=$(kc "$spoke" get infrastructure cluster -o jsonpath='{.status.platform}')
[[ $platform == AWS ]] || die "$spoke is on $platform: only AWS is supported"
infra=$(kc "$spoke" get infrastructure cluster -o jsonpath='{.status.infrastructureName}')

if [[ $action == delete ]]; then
  [[ -n $(kc "$spoke" get machineset -n $ns -l $mark=$kind -o name) ]] || { log "$spoke: no $kind MachineSet from this script"; exit 0; }
  if [[ -n $dry ]]; then kc "$spoke" get machineset -n $ns -l $mark=$kind -o name; exit 0; fi
  kc "$spoke" delete machineset -n $ns -l $mark=$kind --wait=false
  log "$spoke: $kind MachineSet deleting; its machines and nodes go with it"
  exit 0
fi
[[ $action == apply ]] || die "action is apply or delete"

if [[ $kind == gpu ]]; then
  type=${GPU_INSTANCE_TYPE:-g6.xlarge} replicas=${GPU_REPLICAS:-1} az=${GPU_AZ:-} vol=${GPU_VOLUME_SIZE:-120}
  role=gpu taints='[{"key":"nvidia.com/gpu","effect":"NoSchedule"}]'
else
  type=${CPU_INSTANCE_TYPE:-m6a.4xlarge} replicas=${CPU_REPLICAS:-1} az=${CPU_AZ:-} vol=${CPU_VOLUME_SIZE:-120}
  role=cpu-worker taints='[]'
fi
# The clone source: a worker MachineSet that isn't ours or an infra one, in the zone asked for.
ref=$(kc "$spoke" get machineset -n $ns -o json | jq -r --arg az "$az" --arg mark "$mark" '
  [.items[] | select(.metadata.labels[$mark] == null and (.metadata.name | test("-(infra|gpu|cpu-worker)-") | not)
    and ($az == "" or .spec.template.spec.providerSpec.value.placement.availabilityZone == $az))][0].metadata.name // empty')
[[ -n $ref ]] || die "$spoke has no worker MachineSet${az:+ in $az} to clone"
zone=$(kc "$spoke" get machineset "$ref" -n $ns -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
name=$infra-$role-${zone##*-}
log "$spoke: $kind MachineSet $name ($type x$replicas, zone $zone, cloned from $ref)"

yaml=$(kc "$spoke" get machineset "$ref" -n $ns -o json | jq --arg name "$name" --arg infra "$infra" --arg t "$type" --argjson r "$replicas" \
  --arg role "$role" --arg mark "$mark" --arg kind "$kind" --arg vol "$vol" --argjson taints "$taints" '
  {apiVersion, kind, metadata: {name: $name, namespace: .metadata.namespace, labels: (.metadata.labels + {($mark): $kind})},
   spec: {replicas: $r,
     selector: {matchLabels: (.spec.selector.matchLabels + {"machine.openshift.io/cluster-api-machineset": $name})},
     template: {
       metadata: {labels: (.spec.template.metadata.labels + {"machine.openshift.io/cluster-api-machineset": $name,
         "machine.openshift.io/cluster-api-machine-role": $role, "machine.openshift.io/cluster-api-machine-type": $role})},
       spec: (.spec.template.spec | .metadata = {labels: {("node-role.kubernetes.io/" + $role): ""}} | .taints = $taints
         | .providerSpec.value.instanceType = $t
         | if $vol != "" then .providerSpec.value.blockDevices[0].ebs.volumeSize = ($vol | tonumber) else . end)}}}
  | .metadata.labels["machine.openshift.io/cluster-api-cluster"] = $infra')
if [[ -n $dry ]]; then echo "$yaml"; log "dry run: nothing applied"; exit 0; fi
# A MachineSet change reaches only new machines, and the wait below would count the old ones as done.
old=$(kc "$spoke" get machines -n $ns -l machine.openshift.io/cluster-api-machineset="$name" -o json | jq --arg t "$type" --arg vol "$vol" '
  [.items[] | select(.metadata.deletionTimestamp == null) | .spec.providerSpec.value | select(.instanceType != $t or ($vol != "" and (.blockDevices[0].ebs.volumeSize | tostring) != $vol))] | length')
((old == 0)) || die "$spoke: $name has machines that aren't $type${vol:+ with a ${vol}GiB volume}, which a MachineSet change doesn't replace: make spoke-$kind-delete SPOKE=$spoke, then rerun"
kc "$spoke" apply -f - <<<"$yaml" >/dev/null

# Wait for every machine to become a Ready node; a Failed machine ends the wait with its own message.
log "$spoke: waiting for $replicas node(s), usually 5 to 15 minutes"
for ((i = 0; i < 1200; i += 15)); do
  ready=0
  while IFS=$'\x1f' read -r m phase node reason msg; do
    if [[ $phase == Failed ]]; then
      die "machine $m failed: ${reason:-unknown}: ${msg:-no message}. Delete with make spoke-$kind-delete SPOKE=$spoke, then retry with another zone or type"
    fi
    if [[ -n $node && $(kc "$spoke" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; then ready=$((ready + 1)); fi
  done < <(kc "$spoke" get machines -n $ns -l machine.openshift.io/cluster-api-machineset="$name" -o json \
    | jq -r '.items[] | [.metadata.name, .status.phase // "", .status.nodeRef.name // "", .status.errorReason // "", .status.errorMessage // ""] | join("\u001f")')
  if ((ready >= replicas)); then log "$spoke: $ready $kind node(s) Ready"; exit 0; fi
  sleep 15
done
die "$spoke: timed out after 20 min: kc get machines -n $ns -l machine.openshift.io/cluster-api-machineset=$name"
