#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
# The fallback for D4: the ACM Policy does this unless pullSecretMode is script in apps/ai-grid-policies/manifests/values.yaml.
[[ $PULL_SECRET_MODE == script ]] || { log "pullSecretMode=$PULL_SECRET_MODE in git: the ACM Policy handles the pull secret; nothing to do"; exit 0; }
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE: run hack/quay-env.sh (Task 2)"
set -a; source "$ENV_FILE"; set +a   # QUAY_USER, QUAY_TOKEN; never printed
[[ -n "${QUAY_USER:-}" && -n "${QUAY_TOKEN:-}" ]] || die "QUAY_USER or QUAY_TOKEN empty in $ENV_FILE"
# A dockerconfigjson holding only the quay.io/rhoai auth. The token goes through the environment,
# not argv, so it never shows in ps.
PS=$(QA=$(printf '%s:%s' "$QUAY_USER" "$QUAY_TOKEN" | base64 | tr -d '\n') \
  jq -n '{auths: {"quay.io/rhoai": {auth: env.QA}}}')
unset QUAY_TOKEN
for c in $SPOKES; do
  if [[ $(cp_topology "$c") == External ]]; then
    log "$c: hosted control plane: quay.io/rhoai auth as kube-system/additional-pull-secret"
    kc "$c" create secret generic additional-pull-secret -n kube-system \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=<(printf '%s' "$PS") \
      --dry-run=client -o yaml | kc "$c" apply -f - >/dev/null
  else
    log "$c: standard control plane: merge quay.io/rhoai auth into openshift-config/pull-secret"
    merged=$(jq -s '.[0] * .[1]' \
      <(kc "$c" get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d) <(printf '%s' "$PS"))
    kc "$c" set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=<(echo "$merged") >/dev/null
    unset merged
  fi
  log "$c: ImageDigestMirrorSet registry.redhat.io/rhoai -> quay.io/rhoai"
  kc "$c" apply -f - <<'YAML'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata: { name: aigrid-rhoai-nightly }
spec:
  imageDigestMirrors:
    - source: registry.redhat.io/rhoai
      mirrors: [quay.io/rhoai]
YAML
done
log "waiting for nodes to pick up the pull secret and the mirror (standard: node reboots, 15 to 30 minutes)"
for c in $SPOKES; do
  ok=
  for _ in $(seq 1 60); do
    on_node "$c" 'grep -q "quay.io/rhoai" /var/lib/kubelet/config.json && grep -q "quay.io/rhoai" /etc/containers/registries.conf' \
      && { ok=1; break; }
    sleep 30
  done
  [[ -n "$ok" ]] && continue
  if [[ $(cp_topology "$c") == External ]]; then
    die "$c: hosted control plane did not apply the pull secret or the mirror within 30 minutes. If only the mirror is missing, this cluster ignores an IDMS created inside it: stop and ask Chris (see 'Control-plane type')."
  fi
  die "$c: nodes did not pick up the change within 30 minutes; check 'oc get mcp'"
done
