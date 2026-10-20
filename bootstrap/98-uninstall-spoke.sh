#!/usr/bin/env bash
# Removes the AI Grid spoke layer from one spoke, so labelling it again provisions it from zero:
#   CONFIRM=<spoke> bash bootstrap/98-uninstall-spoke.sh <spoke>
# It reads what each of the spoke's Applications deployed (Argo CD's inventory on the hub), unlabels
# the spoke, then deletes, in order: tenant intent, the model, the grid's objects, the portal sign-in,
# the MaaS gateway objects Policies made, OpenShift AI with MaaS (DSC, DSCI, gateways, Kuadrant), their
# operators, and the nightly catalog. It keeps what other layers own or what would reboot nodes: the
# hub's services and its grid site identity (namespace grid stays on local-cluster), the node pull
# secret and image mirror, cert-manager, and CRDs. It stops and names the blocker if something hangs.
source "$(dirname "$0")/lib.sh"
s=${1:?usage: CONFIRM=<spoke> bash bootstrap/98-uninstall-spoke.sh <spoke>}
[[ ${CONFIRM:-} == "$s" ]] || die "this deletes OpenShift AI and MaaS from $s; rerun with CONFIRM=$s"
gone() { # <timeout s> <kc args...>: wait until the object is gone
  local t=$1; shift; for _ in $(seq 1 $((t / 5))); do kc $s get "$@" >/dev/null 2>&1 || return 0; sleep 5; done
  kc $s get "$@" -o jsonpath='{.metadata.finalizers}{" "}{.status.conditions[-1:].message}' 2>/dev/null; echo
  die "still present after ${t}s: $* (finalizers and last condition above)"
}

# 1. Inventory, before unlabelling removes the Applications; kept in out/ so a rerun can finish.
mkdir -p out; inv=out/uninstall-$s.txt
if kc $HOST get applications.argoproj.io platform-$s -n openshift-gitops >/dev/null 2>&1; then
  : > "$inv"
  for a in tenant models grid-consumer grid-provider grid-operator platform limitador-redis maas-db-replica; do
    kc $HOST get applications.argoproj.io $a-$s -n openshift-gitops -o json 2>/dev/null \
      | jq -r --arg a $a '.status.resources[]? | [$a, .group // "", .kind, .namespace // "", .name] | join("|")' >> "$inv"
  done
fi
[[ -s $inv ]] || die "no inventory: the Applications for $s are gone and $inv is missing"
del_app() { # <app> [kind...]: delete what that app deployed, optionally only these kinds
  local a=$1; shift
  # "|", not tabs: read collapses empty tab-separated fields (a core kind's empty group).
  awk -F'|' -v a=$a '$1==a' "$inv" | while IFS='|' read -r _ g k ns n; do
    [[ $# -gt 0 && ! " $* " == *" $k "* ]] && continue
    [[ $k == Namespace && $n == "$GRID_NS" ]] && continue
    kc $s delete "$k${g:+.$g}" "$n" ${ns:+-n $ns} --ignore-not-found --wait=false >/dev/null && echo "  deleted $k ${ns:+$ns/}$n"
  done
}

# 2. Stop delivery and Policies for this spoke.
kc $HOST label managedcluster $s "$LABEL_ENABLED-" "$LABEL_ROLE-" >/dev/null
for _ in $(seq 1 24); do
  [[ -z $(kc $HOST get applications.argoproj.io -n openshift-gitops -o name | grep -- "-$s$") ]] && break; sleep 5
done

log "tenant intent and the model"
del_app tenant
del_app models LLMInferenceService; gone 300 llminferenceservice facebook-opt-125m -n aigrid-models
del_app models

log "the grid's objects (namespace $GRID_NS and the hub site's identity stay)"
del_app grid-consumer; del_app grid-provider
del_app grid-operator InferenceProvider GridSite GridNetwork AgentToolProvider
for k in inferenceproviders gridsites gridnetworks; do
  for o in $(kc $s get $k.grid.praxis.fast -o name 2>/dev/null); do gone 120 "$o"; done
done
del_app grid-operator

log "shared rate-limit Redis and the database replica (Kuadrant's Limitador stays for its operator)"
# Redis first, while its operator still runs to clear its finalizer.
del_app limitador-redis RedisReplication
kc $s get redisreplications.redis.redis.opstreelabs.in limitador-redis -n limitador-redis >/dev/null 2>&1 && gone 300 redisreplications.redis.redis.opstreelabs.in limitador-redis -n limitador-redis
del_app limitador-redis Subscription ServiceExport Secret NetworkPolicy OperatorGroup
for c in $(kc $s get csv -n limitador-redis -o name 2>/dev/null); do kc $s delete $c -n limitador-redis --ignore-not-found; done
kc $s delete ns limitador-redis --ignore-not-found --wait=false
# Never on local-cluster: there namespace maas-db holds the hub's primary database.
if [[ $s != local-cluster ]]; then del_app maas-db-replica Cluster; kc $s delete ns maas-db --ignore-not-found --wait=false; fi
log "Submariner (the add-on removes its agent from $s)"
kc $HOST delete managedclusteraddon submariner -n $s --ignore-not-found
kc $HOST delete submarinerconfigs.submarineraddon.open-cluster-management.io submariner -n $s --ignore-not-found

log "portal sign-in and the MaaS gateway objects Policies made"
kc $s delete ns aigrid-portal-auth ai-tenants --ignore-not-found --wait=false
kc $s delete -n openshift-ingress route/maas-gateway-route configmap/maas-gateway-options configmap/aigrid-gateway-ca-bundle \
  destinationrule.networking.istio.io/maas-portal-tls certificate.cert-manager.io/maas-gw-public-tls secret/maas-gw-public-tls \
  --ignore-not-found

log "OpenShift AI and MaaS"
# Objects with cleanup finalizers go first, while the controllers that clear them still run; deleting
# the DSC removes those controllers and leaves the objects (and their namespaces) stuck.
del_app tenant
for o in $(kc $s get externalmodels.maas.opendatahub.io,externalproviders.maas.opendatahub.io,maassubscriptions.maas.opendatahub.io,maasauthpolicies.maas.opendatahub.io,maasmodelrefs.maas.opendatahub.io -n models-as-a-service -o name 2>/dev/null); do
  gone 300 "$o" -n models-as-a-service
done
kc $s delete aitenants.maas.opendatahub.io --all -n ai-tenants --ignore-not-found --wait=false 2>/dev/null || true
for o in $(kc $s get aitenants.maas.opendatahub.io -n ai-tenants -o name 2>/dev/null); do gone 300 "$o" -n ai-tenants; done
kc $s delete maastenantconfigs.maas.opendatahub.io --all -n models-as-a-service --ignore-not-found --wait=false 2>/dev/null || true
for o in $(kc $s get maastenantconfigs.maas.opendatahub.io -n models-as-a-service -o name 2>/dev/null); do gone 300 "$o" -n models-as-a-service; done
kc $s delete datasciencecluster --all --ignore-not-found --wait=false; for o in $(kc $s get datasciencecluster -o name); do gone 900 $o; done
kc $s delete dscinitialization --all --ignore-not-found --wait=false; for o in $(kc $s get dscinitialization -o name); do gone 600 $o; done
del_app platform Gateway; del_app platform GatewayClass; del_app platform Kuadrant
gone 300 kuadrant kuadrant -n kuadrant-system

log "operators and the nightly catalog"
for ns in redhat-ods-operator kuadrant-system; do
  kc $s delete subscriptions.operators.coreos.com --all -n $ns --ignore-not-found
  # Only CSVs installed here, not copies of cluster-wide operators (Argo CD, CloudNativePG).
  for c in $(kc $s get csv -n $ns -o json | jq -r '.items[] | select(.metadata.labels["olm.copiedFrom"] == null) | .metadata.name'); do
    kc $s delete csv $c -n $ns --ignore-not-found
  done
done
kc $s delete catalogsource rhoai-catalog-dev -n openshift-marketplace --ignore-not-found

log "namespaces"
nss="redhat-ods-applications redhat-ods-monitoring redhat-ods-operator redhat-ai-gateway-infra models-as-a-service kuadrant-system aigrid-models aigrid-portal-auth ai-tenants"
kc $s delete ns $nss --ignore-not-found --wait=false
for n in $nss; do gone 600 ns $n; done
log "spoke layer removed from $s. Provision it again: bash bootstrap/40-spoke.sh (or make spokes)"
