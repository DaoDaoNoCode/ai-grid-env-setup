# shellcheck shell=bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# The hub and its own spoke entry share one kubeconfig; a remote spoke has its own file.
kcfg() {
  case $1 in
    host|local-cluster) echo "$HOST_KUBECONFIG" ;;
    *) echo "$KUBEDIR/$1" ;;
  esac
}
# The file's current context. Never print it: the name can contain the cluster's real host.
kctx() { oc config current-context --kubeconfig "$(kcfg "$1")"; }
kc() { local c=$1; shift; oc --kubeconfig "$(kcfg "$c")" --context "$(kctx "$c")" "$@"; }
# wait_created <cluster> <kind/name> [namespace] [seconds]: until Argo CD has created the object.
# Unlike oc wait --for=create, it also waits while the kind's CRD doesn't exist yet (fresh hub).
wait_created() {
  local c=$1 obj=$2 ns=${3:-} t=${4:-1800} i
  for ((i = 0; i < t; i += 10)); do kc "$c" get "$obj" ${ns:+-n "$ns"} >/dev/null 2>&1 && return 0; sleep 10; done
  die "$obj${ns:+ in $ns} not created within ${t}s: is its Argo CD app synced?"
}
hc() { local c=$1; shift; helm --kubeconfig "$(kcfg "$c")" --kube-context "$(kctx "$c")" "$@"; }
# "a=x b=y" lookups for SPOKE_ROLES and SPOKE_LOCATIONS.
kv() { tr ' ' '\n' <<<"$1" | awk -F= -v k="$2" '$1==k{print $2}'; }
role_of() { kv "$SPOKE_ROLES" "$1"; }
# A spoke's role as the console set it (its ManagedCluster's ai-grid/role on the hub), else SPOKE_ROLES.
site_role() { local r; r=$(kc host get managedcluster "$1" -o json 2>/dev/null | jq -r '.metadata.labels["ai-grid/role"] // ""'); echo "${r:-$(role_of "$1")}"; }
location_of() { kv "$SPOKE_LOCATIONS" "$1"; }
# The spokes whose MaaS portal signs tenants in through maas-cli: every spoke invited in git, and
# local-cluster while it's a grid member or listed in SPOKES, less inference spokes (site_role). SPOKES
# defaults to local-cluster, so make spokes covers the hub before the console's Add; once the hub has
# left the grid, leave it out of SPOKES (46-spoke-join.sh does).
portal_spokes() {
  local s all member
  all=$(yq '.grid-enrollment.invites | keys | .[]' "$REPO_ROOT/apps/grid-enrollment/manifests/values.yaml") || return
  member=$(kc host get managedcluster local-cluster -o json | jq -r --arg l "$LABEL_ENABLED" '.metadata.labels[$l] // ""') || return
  [[ $member != true && " $SPOKES " != *" local-cluster "* ]] || all="local-cluster $all"
  for s in $all; do [[ $(site_role "$s") == inference ]] || echo "$s"; done
}
# A spoke's apps domain from its one console URL claim on the hub (https://console-openshift-console.<apps
# domain>, a bare host name), so no spoke kubeconfig is needed. Empty until ACM's work-manager add-on
# reports the claim, a minute or two after the import.
apps_domain() {
  kc host get managedcluster "$1" -o json | jq -r '[.status.clusterClaims[]? | select(.name == "consoleurl.cluster.open-cluster-management.io") | .value]
    | select(length == 1 and (.[0] | test("^https://console-openshift-console\\.[A-Za-z0-9.-]+$"))) | .[0] | ltrimstr("https://console-openshift-console.")'
}
SITES="" MODEL_SITES=""
for s in $SPOKES; do
  if [[ $s != local-cluster ]]; then SITES+="$s "; fi
  if [[ $(role_of "$s") != ingress ]]; then MODEL_SITES+="$s "; fi
done
export SITES MODEL_SITES
# Scripts that need two clusters (Tasks 10, 11, and 12) skip on a one-cluster build.
multi_only() { [[ -n "${SITES// /}" ]] || { echo "SKIP (no remote spoke)"; exit 0; }; }
# For third-party scripts that use the current context: a kubeconfig holding only this cluster.
with_cluster() { local c=$1; shift; KUBECONFIG="$(kcfg "$c")" "$@"; }
# HighlyAvailable (standard) or External (hosted control plane); see "Control-plane type".
cp_topology() { kc "$1" get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}'; }
# Run a shell command on the cluster's first worker node through a debug pod.
on_node() {
  local n; n=$(kc "$1" get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].metadata.name}')
  kc "$1" debug "node/$n" -q -- chroot /host sh -c "$2"
}
# verify scripts call these inside `bash -c`, which only sees exported functions.
export -f log die kcfg kctx kc hc kv role_of site_role location_of portal_spokes apps_domain multi_only with_cluster cp_topology on_node
