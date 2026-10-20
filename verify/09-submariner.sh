#!/usr/bin/env bash
# Cross-cluster networking: Submariner with Globalnet on every spoke, joined to the hub's broker.
# One cluster has no peer to tunnel to, so this checks the install, not traffic between clusters.
source "$(dirname "$0")/lib.sh"
h=$HOST
uat "broker with globalnet"  "Argo CD app ai-grid-spokes didn't create Broker submariner-broker in default-broker" \
  bash -c "kc $h get brokers.submariner.io submariner-broker -n default-broker -o jsonpath='{.spec.globalnetEnabled}' | grep -qx true"
for s in $SPOKES; do
  # Synced only: with no second cluster there's no tunnel, so the add-on reports
  # SubmarinerConnectionDegraded and Argo CD shows the app Degraded, by design.
  uat "$s submariner app synced" "ApplicationSet ai-grid-submariner: no Application for $s (placement), or a sync error" \
    bash -c "kc $h get applications.argoproj.io submariner-$s -n openshift-gitops -o jsonpath='{.status.sync.status}' | grep -qx Synced"
  uat "$s gateway nodes policy" "Policy submariner-gateway-nodes not Compliant on $s" pol $s submariner-gateway-nodes
  uat "$s two gateway nodes"    "fewer than two nodes whose only role is worker: Submariner's two gateways need them" \
    bash -c "[ \$(kc $s get nodes -l submariner.io/gateway=true --no-headers | wc -l) -ge 2 ]"
  uat "$s submariner addon"     "kc host get managedclusteraddon submariner -n $s -o yaml: the failing condition names the cause" \
    bash -c "kc $h get managedclusteraddon submariner -n $s -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -qx True"
  uat "$s gateways running"     "kc $s get pods -n submariner-operator: gateway pods not scheduled on the labelled nodes" \
    bash -c "[ \$(kc $s get pods -n submariner-operator -l app=submariner-gateway --field-selector=status.phase=Running --no-headers | wc -l) -ge 2 ]"
  uat "$s globalnet running"    "kc $s get pods -n submariner-operator -l app=submariner-globalnet" \
    bash -c "kc $s get pods -n submariner-operator -l app=submariner-globalnet --field-selector=status.phase=Running --no-headers | grep -q ."
  uat "$s service export API"   "Lighthouse (service discovery) not installed: no ServiceExport CRD" \
    kc $s get crd serviceexports.multicluster.x-k8s.io
done
summary
