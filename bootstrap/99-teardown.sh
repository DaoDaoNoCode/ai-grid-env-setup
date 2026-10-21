#!/usr/bin/env bash
# Stops delivery and leaves what it installed: no Application here has a resources finalizer (except
# a remote spoke's submariner-<site>: that spoke leaves the network, as on Remove), every
# ApplicationSet preserves resources on deletion, and ACM Policies don't prune what they
# created. local-cluster's OpenShift AI, the grid and the hub services (ACM, Keycloak, enrollment,
# maas-db) stay running; demo.redhat.com deletes the clusters themselves.
source "$(dirname "$0")/lib.sh"
for s in $SPOKES; do
  kc $HOST get managedcluster $s >/dev/null 2>&1 || continue
  kc $HOST label managedcluster $s "$LABEL_ENABLED-" "$LABEL_ROLE-" >/dev/null
done
# First the root ApplicationSet, so Argo CD can't recreate the delivery Applications.
kc $HOST delete applicationset apps -n openshift-gitops --ignore-not-found
# Then what the two delivery apps (ai-grid-spokes, ai-grid-policies) created, found by Argo CD's
# tracking annotation, then the apps themselves.
owned_by() { # <app> <namespace> <kind>; nothing when the kind isn't installed
  kc $HOST get "$3" -n "$2" -o json 2>/dev/null | jq -r --arg a "$1:" \
    '.items[] | select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith($a)) | "\(.kind)/\(.metadata.name)"' || true
}
kinds="applicationsets.argoproj.io gitopsclusters.apps.open-cluster-management.io policies.policy.open-cluster-management.io
  placementbindings.policy.open-cluster-management.io placements.cluster.open-cluster-management.io
  managedclustersetbindings.cluster.open-cluster-management.io"
for app in ai-grid-spokes ai-grid-policies; do
  for ns in openshift-gitops ai-grid-policies maas-db; do
    kc $HOST get ns $ns >/dev/null 2>&1 || continue
    for k in $kinds; do
      for o in $(owned_by $app $ns $k); do kc $HOST delete -n $ns "$o" --ignore-not-found; done
    done
  done
  kc $HOST delete applications.argoproj.io $app -n openshift-gitops --ignore-not-found
done
for s in $SITES; do kc $HOST delete managedcluster $s --ignore-not-found; done
sites=${SITES% }
# Remote spokes' ManagedClusters are gone, so each needs its import again before the console's Add.
log "delivery stopped; installed software stays. Rebuild: make all${sites:+, then make spoke-join SPOKE=<name> for each remote spoke (${sites// /, })}, then Add to AI Grid in the console"
