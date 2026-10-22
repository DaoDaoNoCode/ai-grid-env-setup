# shellcheck shell=bash
# Sourced by every bootstrap and verify script.
# clusters.local.yaml (git-ignored; see clusters.example.yaml) holds each cluster's API, user and
# password. make login writes their kubeconfigs to CLUSTERS_CACHE, which then is KUBEDIR, and the
# file's git entry gives GIT_REPO and GIT_REF. Variables set in the shell win over the file.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export CLUSTERS_FILE="${CLUSTERS_FILE:-$REPO_ROOT/clusters.local.yaml}" CLUSTERS_CACHE="${CLUSTERS_CACHE:-$REPO_ROOT/.kube-cache}"
if [[ -f $CLUSTERS_FILE ]]; then
  # Once per run: an exported KUBEDIR or HOST_KUBECONFIG from the old flow would silently win.
  if [[ -z ${CLUSTERS_ENV_WARNED:-} ]]; then
    for v in KUBEDIR HOST_KUBECONFIG; do
      [[ -z ${!v:-} || ${!v} == "$CLUSTERS_CACHE"* ]] ||
        printf 'WARNING: %s is set in your shell, so scripts use it, not the make login kubeconfigs: unset %s to use .kube-cache\n' "$v" "$v" >&2
    done
    export CLUSTERS_ENV_WARNED=1
  fi
  export KUBEDIR="${KUBEDIR:-$CLUSTERS_CACHE}"
  GIT_REPO="${GIT_REPO:-$(yq -r '.git.repo // ""' "$CLUSTERS_FILE")}" GIT_REF="${GIT_REF:-$(yq -r '.git.ref // ""' "$CLUSTERS_FILE")}"
  # An unfilled example value would point Argo CD at a repository that doesn't exist.
  if [[ $GIT_REPO$GIT_REF == *"<"*">"* ]]; then
    printf 'ERROR: git.repo or git.ref in %s still has a <placeholder>: fill them in, or delete the git entry for ai-grid-cloud main\n' "$CLUSTERS_FILE" >&2
    return 1
  fi
fi
export KUBEDIR="${KUBEDIR:-$HOME/.kube/aigrid}"
# The hub. Scripts use its kubeconfig file's current context. First build:
# HOST_KUBECONFIG=<workspace>/.config/aio/kubeconfig (passed by path only; set outside git).
export HOST=host
export HOST_KUBECONFIG="${HOST_KUBECONFIG:-$KUBEDIR/host}"
# Spokes: ManagedCluster names that get AI Grid. local-cluster is the hub itself (D1, 2026-10-19).
# A remote spoke's kubeconfig is $KUBEDIR/<name>, used to import it (Task 11) and by its verify checks.
export SPOKES="${SPOKES:-local-cluster}"
export SPOKE_ROLES="${SPOKE_ROLES:-local-cluster=combined}"       # ingress | inference | combined
export SPOKE_LOCATIONS="${SPOKE_LOCATIONS:-local-cluster=us-east}"
# The deployer's quay.io/rhoai login (QUAY_USER, QUAY_TOKEN), git-ignored, written by hack/quay-env.sh
# (Task 2). Read only by bootstrap/25-hub-secrets.sh and the fallback bootstrap/10-pull-secret.sh (Task 5).
export ENV_FILE="${ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env}"
# Versions and pins (the nightly catalog, odh-gitops, the grid) live in apps/*/manifests/values.yaml,
# which Argo CD reads; the scripts below only read the few facts they need from git.
# D4: policy (ACM Policy rhoai-pull-secret) or script (fallback bootstrap/10-pull-secret.sh), as set
# in git, so the script and the Policy can't both act.
export PULL_SECRET_MODE=$(awk '$1=="pullSecretMode:"{print $2}' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apps/ai-grid-policies/manifests/values.yaml")
# Keycloak's namespace on the hub, as apps/keycloak/application.yaml sets it (change both together).
export KEYCLOAK_NS=keycloak
export GRID_NS=grid                                 # the grid's namespace on every spoke (gridNs in git)
export MODEL_NAME=facebook-opt-125m                 # the fixture model's MaaS ID (spokes/models/opt-125m)
export LABEL_ENABLED=ai-grid/enabled LABEL_ROLE=ai-grid/role LABEL_LOCATION=location
export LABEL_UNINSTALLING=ai-grid/uninstalling   # keeps a spoke on the network during 98-uninstall-spoke.sh
# The git source Argo CD builds the hub and spokes from. To try a branch, set both before make hub, e.g.
# GIT_REPO=https://github.com/<you>/ai-grid-env-setup.git GIT_REF=<branch>, or set git: in clusters.local.yaml.
export GIT_REPO="${GIT_REPO:-https://github.com/ai-grid-cloud/ai-grid-env-setup.git}" GIT_REF="${GIT_REF:-main}"
# Provider console images and commits are pinned in apps/console/manifests (runbook, Provider console).
