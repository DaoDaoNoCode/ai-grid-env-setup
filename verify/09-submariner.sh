#!/usr/bin/env bash
# Cross-cluster networking: Submariner with Globalnet on the hub's local-cluster and every remote
# spoke (Placement ai-grid-network), joined to the hub's broker. With a remote spoke it also checks
# the tunnels and that the spoke reaches the hub's maas-db by its clusterset name.
source "$(dirname "$0")/lib.sh"
h=$HOST
uat "broker with globalnet"  "Argo CD app ai-grid-spokes didn't create Broker submariner-broker in default-broker" \
  bash -c "kc $h get brokers.submariner.io submariner-broker -n default-broker -o jsonpath='{.spec.globalnetEnabled}' | grep -qx true"
NETWORK="local-cluster $SITES"
n=$(wc -w <<<"$NETWORK")
for s in $NETWORK; do
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
  if (( n > 1 )); then
    uat "$s tunnels to the other $((n - 1)) cluster(s)" "IPsec through the gateways' load balancers (SubmarinerConfig loadBalancerEnable): kc $s get gateways.submariner.io -n submariner-operator -o yaml (status.connections)" \
      bash -c "kc $s get gateways.submariner.io -n submariner-operator -o json | jq -e '[.items[].status.connections[]? | select(.status==\"connected\")] | length >= $((n - 1))'"
  fi
  if [[ $s != local-cluster ]]; then
    # From an ordinary pod on the spoke (Lighthouse's agent): DNS, the tunnel and Globalnet together.
    for svc in maas-db-rw.maas-db:5432 grid-enrollment.grid-enrollment:8443; do
      uat "$s reaches local-cluster.${svc%%:*}.svc.clusterset.local" "no ServiceImport (Policy clusterset-namespaces: the namespace must exist on $s), the tunnel, or the hub's NetworkPolicy" \
        bash -c "kc $s exec -n submariner-operator deploy/submariner-lighthouse-agent -- timeout 5 bash -c '</dev/tcp/local-cluster.${svc%%:*}.svc.clusterset.local/${svc##*:}'"
    done
  fi
done
# Leaving the network removes the add-on (the app's resources finalizer): no cluster but the hub and the
# ones Placement ai-grid-network selects now (grid members, and joined clusters labelled
# ai-grid/network) keeps it, and with it a route to the hub's maas-db and enrollment. Actual decisions,
# not SPOKES, so a removed spoke still listed there counts.
uat "only members and joined clusters on the network" "a cluster Placement ai-grid-network doesn't select keeps managedclusteraddon submariner (the add-on outlived its Application; runbook Known gaps): kc host delete managedclusteraddon submariner -n <cluster>" \
  bash -c "m=\$(kc $h get placementdecisions -n openshift-gitops -l cluster.open-cluster-management.io/placement=ai-grid-network -o jsonpath='{.items[*].status.decisions[*].clusterName}') || exit 1; a=\$(kc $h get managedclusteraddon -A --field-selector metadata.name=submariner -o jsonpath='{.items[*].metadata.namespace}') || exit 1; for c in \$a; do case \" local-cluster \$m \" in *\" \$c \"*) ;; *) exit 1;; esac; done"
summary
