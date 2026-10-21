#!/usr/bin/env bash
# Imports each remote spoke into the hub's ACM, so the console can add it to AI Grid:
#   bash bootstrap/45-import.sh            (every remote spoke in SPOKES; kubeconfig $KUBEDIR/<name>)
# Importing isn't membership: the ManagedCluster gets no ai-grid/enabled or ai-grid/role. ACM uses the spoke's
# kubeconfig once, through its auto-import Secret, to install the klusterlet, and then deletes the
# Secret. The kubeconfig reaches the hub through a file descriptor, never argv or output.
source "$(dirname "$0")/lib.sh"
multi_only
for s in $SITES; do
  kc $HOST apply -f - >/dev/null <<YAML
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: $s
  # No ai-grid/* labels: it joins the cross-cluster network (Submariner) only when the console adds
  # it to AI Grid, so a cluster that isn't a member gets no route to the hub's maas-db or enrollment.
  labels: { cluster.open-cluster-management.io/clusterset: default, cloud: auto-detect, vendor: auto-detect }
spec: { hubAcceptsClient: true }
YAML
  # ACM creates the cluster's namespace on the hub once it registers the ManagedCluster.
  kc $HOST wait --for=create ns/$s --timeout=2m >/dev/null
  kc $HOST apply -f - >/dev/null <<YAML
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata: { name: $s, namespace: $s }
spec:
  applicationManager: { enabled: true }
  certPolicyController: { enabled: true }
  policyController: { enabled: true }
  searchCollector: { enabled: true }
YAML
  if [[ $(kc $HOST get managedcluster $s -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}') != True ]]; then
    kc $HOST create secret generic auto-import-secret -n $s --from-literal=autoImportRetry=5 \
      --from-file=kubeconfig=<(oc config view --raw --minify --flatten --kubeconfig "$(kcfg $s)" --context "$(kctx $s)") \
      --dry-run=client -o yaml | kc $HOST apply -f - >/dev/null
    log "$s: auto-import started"
  fi
  # ACM deletes the auto-import Secret only after a successful import; on a timeout it would keep
  # the spoke's admin kubeconfig, so delete it here.
  kc $HOST wait managedcluster/$s --for=condition=ManagedClusterConditionAvailable --timeout=15m || {
    kc $HOST delete secret auto-import-secret -n $s --ignore-not-found >/dev/null
    die "$s not available after 15m; deleted its auto-import-secret (the spoke's admin kubeconfig). Fix the cause and rerun"
  }
done
