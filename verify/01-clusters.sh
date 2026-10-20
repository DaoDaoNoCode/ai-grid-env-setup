#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
for c in $HOST $SITES; do
  uat "$c reachable"        "HOST_KUBECONFIG unset, or the token expired: Chris runs oc login again (Step 4)" kc "$c" get --raw /readyz
  uat "$c cluster-admin"    "logged in as a user without cluster-admin" bash -c "kc $c auth can-i '*' '*' --all-namespaces | grep -qx yes"
  uat "$c OpenShift >=4.20" "the MaaS and grid charts need 4.20 or later" bash -c "kc $c get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F. '\$1==4 && \$2>=20{ok=1} END{exit !ok}'"
  uat "$c >=3 workers"      "too few schedulable nodes for OpenShift AI, ACM, and the model" bash -c "[ \$(kc $c get nodes -l node-role.kubernetes.io/worker= --no-headers | wc -l) -ge 3 ]"
  uat "$c gp3-csi default"  "no default AWS storage class: PVCs (maas-db, enrollment) would stay Pending" bash -c "kc $c get sc gp3-csi -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -qx true"
done
for c in $SPOKES; do   # local-cluster runs on the hub's kubeconfig
  uat "$c node has quay.io/rhoai auth" "Policy rhoai-pull-secret not enforced yet, or the fallback not run" \
    on_node "$c" 'grep -q "quay.io/rhoai" /var/lib/kubelet/config.json'
  uat "$c node mirrors rhoai" "Policy rhoai-nightly-prereqs hasn't created the IDMS, or nodes still rolling" \
    on_node "$c" 'grep -q "quay.io/rhoai" /etc/containers/registries.conf'
done
summary
