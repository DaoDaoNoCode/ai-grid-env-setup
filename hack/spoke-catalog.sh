#!/usr/bin/env bash
# Warms a spoke's nightly OpenShift AI catalog before its Add, against the spoke's own kubeconfig
# ($KUBEDIR/<spoke>):
#   bash hack/spoke-catalog.sh <spoke>
# The nightly catalog is global (openshift-marketplace), and while its pod pulls and starts (about 6
# minutes on a cold node) OLM fails every Subscription on the cluster, then backs off: on a fresh
# spoke, Submariner and the other operators waited about 17 minutes after the Add (site-b,
# 2026-10-22). Ready before the Add, it holds nothing up.
# It writes what Policies rhoai-pull-secret and rhoai-nightly-prereqs write after the Add, so they
# find them in place: the quay.io/rhoai auth merged into openshift-config/pull-secret (compact JSON
# with sorted keys, as the Policy renders it), and CatalogSource rhoai-catalog-dev exactly as the
# Policy renders it from apps/ai-grid-policies. Not the ImageDigestMirrorSet: the catalog pulls from
# quay.io directly, and the mirror's MachineConfig rollout stays with the Policy. Rerun-safe.
source "$(dirname "$0")/../bootstrap/lib.sh"
set +x   # the quay.io login passes through variables here; xtrace would print it
spoke=${1:?usage: spoke-catalog.sh <spoke>}
cd "$(dirname "$0")/.." || exit
[[ -f $(kcfg "$spoke") ]] || die "no kubeconfig for $spoke: expected $(kcfg "$spoke")"
cs=$(helm template ci apps/ai-grid-policies/manifests | yq -o json 'select(.kind == "Policy" and .metadata.name == "rhoai-nightly-prereqs")
  | .spec.policy-templates[].objectDefinition.spec.object-templates[].objectDefinition | select(.kind == "CatalogSource")')
image=$(jq -r .spec.image <<<"$cs")
[[ -n $image && $image != null ]] || die "no CatalogSource in Policy rhoai-nightly-prereqs (apps/ai-grid-policies)"
state() { kc "$spoke" get catalogsource rhoai-catalog-dev -n openshift-marketplace -o jsonpath='{.spec.image} {.status.connectionState.lastObservedState}' 2>/dev/null; }
if [[ $(state) == "$image READY" ]]; then log "$spoke: catalog rhoai-catalog-dev already READY at the pinned image"; exit 0; fi
if [[ $(cp_topology "$spoke") == External ]]; then
  log "$spoke: hosted control plane: Policy rhoai-pull-secret can't set its pull secret; skipped (see bootstrap/10-pull-secret.sh)"; exit 0
fi
[[ -f $ENV_FILE ]] || { log "$spoke: skipped: no $ENV_FILE (run hack/quay-env.sh); the catalog comes with the Add instead"; exit 0; }
# The login stays in this subshell's environment and reaches the cluster through a pipe and a file
# descriptor, never argv; never printed. Exit 3: skipped.
rc=0
(
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  [[ -n ${QUAY_USER:-} && -n ${QUAY_TOKEN:-} ]] || { log "$spoke: skipped: QUAY_USER or QUAY_TOKEN empty in $ENV_FILE"; exit 3; }
  QA=$(printf '%s:%s' "$QUAY_USER" "$QUAY_TOKEN" | base64 | tr -d '\n'); export QA; unset QUAY_TOKEN
  cur=$(kc "$spoke" get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  if [[ $(jq -r '.auths["quay.io/rhoai"].auth // ""' <<<"$cur") == "$QA" ]]; then
    log "$spoke: pull secret already has the quay.io/rhoai auth"
  else
    log "$spoke: merging the quay.io/rhoai auth into openshift-config/pull-secret (nodes pick it up without a reboot)"
    kc "$spoke" set data secret/pull-secret -n openshift-config \
      --from-file=.dockerconfigjson=<(jq -cS '.auths["quay.io/rhoai"] = {auth: env.QA}' <<<"$cur") >/dev/null
  fi
) || rc=$?
case $rc in 0) ;; 3) exit 0 ;; *) die "$spoke: pull secret not updated" ;; esac
log "$spoke: CatalogSource rhoai-catalog-dev ($image)"
jq '.metadata.namespace = "openshift-marketplace"' <<<"$cs" | kc "$spoke" apply -f - >/dev/null
for _ in $(seq 1 60); do
  [[ $(state) == "$image READY" ]] && { log "$spoke: catalog READY; Add the spoke when ready"; exit 0; }
  sleep 20
done
die "$spoke: catalog not READY after 20 minutes: kc $spoke get pods -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-dev (an image pull error means the nodes don't have the pull secret yet: oc get mcp)"
