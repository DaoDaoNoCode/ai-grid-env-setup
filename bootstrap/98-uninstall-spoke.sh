#!/usr/bin/env bash
# Removes the AI Grid spoke layer from one spoke, so labelling it again provisions it from zero:
#   make spoke-uninstall SPOKE=<spoke>      (asks for the name at a terminal; otherwise CONFIRM=<spoke>)
#   CONFIRM=<spoke> bash bootstrap/98-uninstall-spoke.sh <spoke>
# Run it instead of Remove in the console, not after: it reads the spoke's Applications, which Remove deletes.
# It reads what each of the spoke's Applications deployed (Argo CD's inventory on the hub), unlabels
# the spoke, then deletes, in order: tenant intent, the model, the grid's objects, the portal sign-in,
# the MaaS gateway objects Policies made, the MaaS objects with cleanup finalizers (subscriptions, then
# the AITenant, which revokes its keys and then removes its MaaSTenantConfig), then takes a remote spoke
# off the cross-cluster network (and its maas-db replica), then OpenShift AI (DSC, DSCI, gateways,
# Kuadrant), its operators, and the nightly catalog. On a spoke that
# serves tenants it stops while another ingress or combined spoke is a member, unless
# REVOKE_TENANT_KEYS=1: the AITenant's cleanup revokes every tenant API key in the shared maas-db.
# It keeps what other layers own or what would reboot nodes: the hub's services and its grid site
# identity (namespace grid stays on local-cluster), the node pull secret and image mirror,
# cert-manager, and CRDs. It stops and names the blocker if something hangs.
# KEEP_PREREQS=1 removes only the AI Grid layer from a remote spoke and keeps what a cluster brings as
# prerequisites: the cross-cluster network (Submariner stays, through label ai-grid/network), the GPU
# node, NFD and the GPU operator (never removed), the nightly catalog, and the site's grid identity and
# its provider's exported Service, so the next Add comes back at the same Globalnet address with the
# same certificate and its pinned digest still matches.
source "$(dirname "$0")/lib.sh"
s=${1:?usage: CONFIRM=<spoke> bash bootstrap/98-uninstall-spoke.sh <spoke>}
if [[ -z ${CONFIRM:-} && -t 0 ]]; then
  read -r -p "This deletes OpenShift AI, MaaS and the grid from $s. Type the spoke name to confirm: " CONFIRM
fi
keep=${KEEP_PREREQS:-}; [[ $keep == 1 ]] || keep=
[[ -n $keep && $s == local-cluster ]] && die "KEEP_PREREQS is for a remote spoke; local-cluster keeps its network anyway"
[[ ${CONFIRM:-} == "$s" ]] || die "this deletes OpenShift AI, MaaS and the grid from $s; confirm with: make spoke-uninstall SPOKE=$s CONFIRM=$s"
# Kinds gone() is called with whose CRD may never have arrived, on a spoke whose install stopped before
# KServe or Kuadrant: nothing of that kind exists. Uninstalling keeps CRDs, so a rerun still has them.
# Any other unknown kind is a typo here, and stops the script rather than skip its wait.
may_lack_crd="llminferenceservice kuadrant"
gone() { # <timeout s> <kc args...>: wait until the object is gone; any other error stops
  local t=$1 err; shift
  for _ in $(seq 1 $((t / 5))); do
    if ! err=$(kc $s get "$@" -o name 2>&1 >/dev/null); then
      [[ $err == *NotFound* ]] && return 0
      [[ $err == *"doesn't have a resource type"* && " $may_lack_crd " == *" $1 "* ]] && return 0
      die "can't check $*: $err"
    fi
    sleep 5
  done
  kc $s get "$@" -o jsonpath='{.metadata.finalizers}{" "}{.status.conditions[-1:].message}' 2>/dev/null; echo
  die "still present after ${t}s: $* (finalizers and last condition above)"
}
names() { # <resource> <namespace>: its objects, none if the kind's CRD never arrived; any other error stops
  local crd
  kc $s get "$1" -n "$2" -o name 2>/dev/null && return
  crd=$(kc $s get crd "$1" --ignore-not-found -o name) && [[ -z $crd ]] ||
    die "can't list $1 in $2 on $s: rerun when the spoke answers (if the token expired, run make login)"
}

# 1. Inventory, before unlabelling removes the Applications; kept in out/ so a rerun can finish.
out="$(cd "$(dirname "$0")/.." && pwd)/out"; mkdir -p "$out"; inv=$out/uninstall-$s.txt
if err=$(kc $HOST get applications.argoproj.io platform-$s -n openshift-gitops -o name 2>&1 >/dev/null); then
  : > "$inv"
  # Only the Applications this spoke has: which ones exist depends on its role and on whether it's the hub.
  for a in $(kc $HOST get applications.argoproj.io -n openshift-gitops -o name | sed -n "s|^application.argoproj.io/\(.*\)-$s\$|\1|p"); do
    kc $HOST get applications.argoproj.io $a-$s -n openshift-gitops -o json \
      | jq -r --arg a $a '.status.resources[]? | [$a, .group // "", .kind, .namespace // "", .name] | join("|")' >> "$inv"
  done
elif [[ $err != *NotFound* ]]; then
  die "can't read $s's Applications on the hub (${err##*: }): check the hub is reachable and, if the token expired, run make login; then rerun"
fi
if [[ ! -s $inv ]]; then
  mc=$(kc $HOST get managedcluster $s -o json 2>/dev/null) || die "no ManagedCluster $s on the hub: check the spoke name"
  [[ $(jq -r --arg l "$LABEL_ENABLED" '.metadata.labels[$l] // ""' <<<"$mc") != true ]] ||
    die "$s is in AI Grid but its apps aren't on the hub yet: wait until they're Synced (about 2 min), then rerun make spoke-uninstall SPOKE=$s"
  die "$s was already removed in the console, so its app list is gone. Add it again in the console, wait until its apps are Synced (about 2 min), then rerun make spoke-uninstall SPOKE=$s"
fi
# Deleting the AITenant on a spoke that serves tenants (app tenant-<spoke>: ingress or combined) revokes
# every API key of the tenant in the shared maas-db, including keys used through another ingress spoke.
if [[ -n $(awk -F'|' '$1=="tenant"' "$inv") && ${REVOKE_TENANT_KEYS:-} != 1 ]]; then
  mcs=$(kc $HOST get managedclusters -l "$LABEL_ENABLED=true,$LABEL_ROLE in (ingress,combined)" -o name) ||
    die "can't list the hub's ManagedClusters to check for other spokes that serve tenants; rerun when the hub answers"
  others=$(sed 's|.*/||' <<<"$mcs" | grep -vx "$s" | tr '\n' ' ' || true)
  [[ -z ${others// /} ]] || die "$s serves tenants, and so does ${others% }: uninstalling $s revokes every tenant API key in the shared maas-db, theirs included. Rerun with REVOKE_TENANT_KEYS=1 to accept that"
fi
del_app() { # <app> [kind...]: delete what that app deployed, optionally only these kinds
  local a=$1; shift
  # "|", not tabs: read collapses empty tab-separated fields (a core kind's empty group).
  awk -F'|' -v a=$a '$1==a' "$inv" | while IFS='|' read -r _ g k ns n; do
    [[ $# -gt 0 && ! " $* " == *" $k "* ]] && continue
    [[ $k == Namespace && $n == "$GRID_NS" ]] && continue
    kc $s delete "$k${g:+.$g}" "$n" ${ns:+-n $ns} --ignore-not-found --wait=false >/dev/null && echo "  deleted $k ${ns:+$ns/}$n"
  done
}

# 2. Stop delivery and Policies for this spoke. A remote spoke stays on the cross-cluster network
# (label ai-grid/uninstalling, which Placement ai-grid-network also selects) until the MaaS objects are
# gone, since their cleanup revokes API keys in the hub's maas-db through it. A run that stops keeps
# the label, so a rerun still has the route; step 4 removes it.
[[ -n $keep ]] && kc $HOST label managedcluster $s "$LABEL_NETWORK=true" --overwrite >/dev/null
if [[ $s != local-cluster ]]; then
  kc $HOST label managedcluster $s "$LABEL_UNINSTALLING=true" --overwrite >/dev/null
  trap 'rc=$?; ((rc == 0)) || log "$s keeps $LABEL_UNINSTALLING=true, and with it its route to the hub: rerun make spoke-uninstall SPOKE=$s to finish, or remove it on the hub with oc label managedcluster $s $LABEL_UNINSTALLING-"' EXIT
  trap 'exit 130' INT TERM   # so Ctrl-C also reports the label
fi
kc $HOST label managedcluster $s "$LABEL_ENABLED-" "$LABEL_ROLE-" >/dev/null
for _ in $(seq 1 24); do
  # Submariner's app follows the network, not the grid: the hub's stays (removed below for a remote spoke).
  [[ -z $(kc $HOST get applications.argoproj.io -n openshift-gitops -o name | grep -- "-$s$" | grep -v "/submariner-") ]] && break; sleep 5
done

log "tenant intent and the model"
del_app tenant
del_app models LLMInferenceService; gone 300 llminferenceservice facebook-opt-125m -n aigrid-models
del_app models

log "the grid's objects (namespace $GRID_NS and the hub site's identity stay)"
if [[ -n $keep ]]; then
  # The exported Service holds the site's Globalnet address: keep it and its ServiceExport.
  del_app grid-consumer; del_app grid-provider Deployment ConfigMap; kc $s delete service grid-provider -n $GRID_NS --ignore-not-found >/dev/null
else
  del_app grid-consumer; del_app grid-provider-export; del_app grid-provider
fi
del_app grid-operator InferenceProvider GridSite GridNetwork AgentToolProvider
for k in inferenceproviders gridsites gridnetworks; do
  for o in $(kc $s get $k.grid.praxis.fast -o name 2>/dev/null); do gone 120 "$o"; done
done
del_app grid-operator

log "shared rate-limit Redis (Kuadrant's Limitador stays for its operator)"
# Redis first, while its operator still runs to clear its finalizer.
del_app limitador-redis RedisReplication
kc $s get redisreplications.redis.redis.opstreelabs.in limitador-redis -n limitador-redis >/dev/null 2>&1 && gone 300 redisreplications.redis.redis.opstreelabs.in limitador-redis -n limitador-redis
del_app limitador-redis Subscription ServiceExport Secret NetworkPolicy OperatorGroup
for c in $(kc $s get csv -n limitador-redis -o name 2>/dev/null); do kc $s delete $c -n limitador-redis --ignore-not-found; done
kc $s delete ns limitador-redis --ignore-not-found --wait=false
[[ $s == local-cluster ]] && log "Submariner stays on local-cluster: the hub's maas-db and grid enrollment are reached through it"

log "portal sign-in and the MaaS gateway objects Policies made"
# Namespace ai-tenants stays until its AITenant has run its cleanup (below).
kc $s delete ns aigrid-portal-auth --ignore-not-found --wait=false
kc $s delete -n openshift-ingress route/maas-gateway-route configmap/maas-gateway-options configmap/aigrid-gateway-ca-bundle \
  destinationrule.networking.istio.io/maas-portal-tls certificate.cert-manager.io/maas-gw-public-tls secret/maas-gw-public-tls \
  --ignore-not-found

log "OpenShift AI and MaaS"
# Objects with cleanup finalizers go first, while the controllers that clear them still run; deleting
# the DSC removes those controllers and leaves the objects (and their namespaces) stuck.
del_app tenant
# ExternalModel and ExternalProvider are inference.opendatahub.io; the rest are maas.opendatahub.io.
# A failed lookup stops here rather than skip these and strand them on their finalizers. A kind whose
# CRD never arrived (an inference spoke has no MaaS) has none.
objs=""
for r in externalmodels.inference.opendatahub.io externalproviders.inference.opendatahub.io maassubscriptions.maas.opendatahub.io \
  maasauthpolicies.maas.opendatahub.io maasmodelrefs.maas.opendatahub.io; do
  objs+=" $(names $r models-as-a-service)" || die "can't list $r in models-as-a-service on $s"
done
for o in $objs; do gone 300 "$o" -n models-as-a-service; done
# The AITenant goes first, while the spoke still reaches the hub's maas-db: its cleanup revokes the
# tenant's API keys, then deletes its MaaSTenantConfig, whose cleanup needs the AITenant to resolve.
# Deleting the MaaSTenantConfig first would take maas-api down before the revoke.
kc $s delete aitenants.maas.opendatahub.io --all -n ai-tenants --ignore-not-found --wait=false 2>/dev/null || true
# A failed list stops here, keeping the hold label: going on would take the spoke off the network before the revoke.
objs=$(names aitenants.maas.opendatahub.io ai-tenants)
for o in $objs; do gone 300 "$o" -n ai-tenants; done
# Normally gone with its AITenant. A leftover whose AITenant is already gone can loop in
# ai-gateway-controller's praxis-cleanup ("owning AITenant is not resolvable yet"): the wait then stops
# and names that finalizer, which has to be removed by hand.
kc $s delete maastenantconfigs.maas.opendatahub.io --all -n models-as-a-service --ignore-not-found --wait=false 2>/dev/null || true
objs=$(names maastenantconfigs.maas.opendatahub.io models-as-a-service)
for o in $objs; do gone 300 "$o" -n models-as-a-service; done

# 4. The MaaS cleanup is done: a remote spoke leaves the cross-cluster network.
if [[ -n $keep ]]; then
  log "staying on the cross-cluster network ($LABEL_NETWORK)"
  kc $HOST label managedcluster $s "$LABEL_UNINSTALLING-" >/dev/null
  trap - EXIT
elif [[ $s != local-cluster ]]; then
  log "leaving the cross-cluster network (Submariner's add-on removes its agent from $s)"
  kc $HOST label managedcluster $s "$LABEL_UNINSTALLING-" "$LABEL_NETWORK-" >/dev/null
  trap - EXIT
  # Wait for the network Placement to drop the spoke first: while its decision still lists $s, the
  # ApplicationSet recreates submariner-$s, which re-applies the add-on. Once it's dropped, deleting
  # the app prunes the add-on (its resources finalizer, as on Remove in the console); the deletes
  # after it are for an app made before that finalizer, and are no-ops otherwise.
  for _ in $(seq 1 24); do
    [[ " $(kc $HOST get placementdecisions -n openshift-gitops \
      -l cluster.open-cluster-management.io/placement=ai-grid-network \
      -o jsonpath='{.items[*].status.decisions[*].clusterName}') " != *" $s "* ]] && break
    sleep 5
  done
  [[ " $(kc $HOST get placementdecisions -n openshift-gitops \
    -l cluster.open-cluster-management.io/placement=ai-grid-network \
    -o jsonpath='{.items[*].status.decisions[*].clusterName}') " != *" $s "* ]] ||
    die "Placement ai-grid-network still selects $s after 120s; check its labels and rerun"
  kc $HOST delete applications.argoproj.io submariner-$s -n openshift-gitops --ignore-not-found --wait=false >/dev/null
  kc $HOST delete managedclusteraddon submariner -n $s --ignore-not-found
  kc $HOST delete submarinerconfigs.submarineraddon.open-cluster-management.io submariner -n $s --ignore-not-found
  # The maas-db replica, now that the spoke is off the network: namespace maas-db also names the hub's
  # imported maas-db-rw, and Policy clusterset-namespaces would recreate it while the spoke was on it.
  # Never on local-cluster: there namespace maas-db holds the hub's primary database.
  del_app maas-db-replica Cluster; kc $s delete ns maas-db --ignore-not-found --wait=false
fi
kc $s delete datasciencecluster --all --ignore-not-found --wait=false; for o in $(kc $s get datasciencecluster -o name); do gone 900 $o; done
kc $s delete dscinitialization --all --ignore-not-found --wait=false; for o in $(kc $s get dscinitialization -o name); do gone 600 $o; done
del_app platform Gateway; del_app platform GatewayClass; del_app platform Kuadrant
gone 300 kuadrant kuadrant -n kuadrant-system

if [[ -n $keep ]]; then log "operators (the nightly catalog stays)"; else log "operators and the nightly catalog"; fi
for ns in redhat-ods-operator kuadrant-system; do
  kc $s delete subscriptions.operators.coreos.com --all -n $ns --ignore-not-found
  # Only CSVs installed here, not copies of cluster-wide operators (Argo CD, CloudNativePG).
  for c in $(kc $s get csv -n $ns -o json | jq -r '.items[] | select(.metadata.labels["olm.copiedFrom"] == null) | .metadata.name'); do
    kc $s delete csv $c -n $ns --ignore-not-found
  done
done
[[ -n $keep ]] || kc $s delete catalogsource rhoai-catalog-dev -n openshift-marketplace --ignore-not-found

log "namespaces"
nss="redhat-ods-applications redhat-ods-monitoring redhat-ods-operator redhat-ai-gateway-infra models-as-a-service kuadrant-system aigrid-models aigrid-portal-auth ai-tenants"
kc $s delete ns $nss --ignore-not-found --wait=false
for n in $nss; do gone 600 ns $n; done
log "spoke layer removed from $s. Provision it again: Add to AI Grid in the console (dev shortcut: bash bootstrap/40-spoke.sh)"
