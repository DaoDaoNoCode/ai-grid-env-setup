#!/usr/bin/env bash
# The provider console on the hub (Task 9): built on the hub, signed in with the cluster's OpenShift
# login, and its BFF reaching the backend. Until the console and backend agree on gRPC names, the
# backend answers Clusters and Organizations with Unimplemented (HTTP 501); that's expected for now.
source "$(dirname "$0")/lib.sh"
ns=ai-grid name=ai-grid-provider-console
host=$(kc $HOST get route $name -n $ns -o jsonpath='{.spec.host}' 2>/dev/null)
build_ok() { [[ $(kc $HOST get builds -n $ns -l buildconfig=$1 --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.phase}') == Complete ]]; }
export -f build_ok; export ns name
uat "app console"         "Argo CD app not Synced/Healthy: the remote kustomize base, or the pod (secrets from bootstrap/60-console.sh)" app console
# The pod runs exactly the images git pins (component images/ghcr by default, images/in-cluster as fallback).
pinned=$(oc kustomize "$(dirname "$0")/../apps/console/manifests" 2>/dev/null | yq 'select(.kind=="Deployment").spec.template.spec.containers[] | select(.name=="bff" or .name=="ai-grid-backend") | .image')
live=$(kc $HOST get deploy $name -n $ns -o json | jq -r '.spec.template.spec.containers[] | select(.name=="bff" or .name=="ai-grid-backend") | .image')
export pinned live
uat "console images pinned by digest" "an image in apps/console/manifests/images lacks @sha256: a tag alone can be overwritten" \
  bash -c '[[ $(grep -c "@sha256:" <<<"$pinned") == 2 || $pinned == *image-registry.openshift-image-registry.svc* ]]'
uat "console runs the pinned images" "Argo CD app console not synced to git's image tags, or the render failed (oc kustomize apps/console/manifests)" \
  bash -c '[[ -n $pinned && $pinned == "$live" ]]'
if grep -q '^  - ./images/in-cluster' "$(dirname "$0")/../apps/console/manifests/kustomization.yaml"; then
  uat "console image built" "BuildConfig ai-grid-provider-console: oc logs -n $ns bc/ai-grid-provider-console" build_ok ai-grid-provider-console
  uat "backend image built" "BuildConfig ai-grid-backend: oc logs -n $ns bc/ai-grid-backend" build_ok ai-grid-backend
else
  uat "console images pull" "ghcr.io package private (make it Public) or tag missing: kc host get pods -n $ns" \
    bash -c "! kc $HOST get pods -n $ns -l app.kubernetes.io/name=$name -o json | jq -e '[.items[].status.containerStatuses[]?.state.waiting.reason // empty] | map(select(test(\"ImagePull|ErrImage\"))) | length > 0' >/dev/null"
fi
uat "console pod ready"   "secrets missing (bootstrap/60-console.sh), or the BFF's /readyz can't ping the backend" \
  kc $HOST rollout status deploy/$name -n $ns --timeout=5s
uat "backend REST on loopback" "the backend's REST gateway listens on the pod network without authentication" \
  bash -c "kc $HOST get deploy $name -n $ns -o json | jq -e '.spec.template.spec.containers[] | select(.name==\"ai-grid-backend\") | .args | index(\"--http-listen-address=127.0.0.1:8081\")'"
uat "sign-in goes to OpenShift" "OAuthClient $name or Secret $name-oauth missing (bootstrap/60-console.sh)" \
  bash -c "curl -s -o /dev/null -w '%{redirect_url}' https://$host/ | grep -q '/oauth2/start\|oauth-openshift\|/oauth/authorize'"
uat "BFF reaches backend" "/readyz pings the backend over loopback; the backend container isn't serving" \
  bash -c "curl -s -o /dev/null -w '%{http_code}' https://$host/readyz | grep -qx 200"
# A signed-in provider admin's call: the token reaches curl through a file descriptor, never argv.
code=$(curl -s -o /dev/null -w '%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$(kc $HOST whoami -t)") "https://$host/api/v1/clusters")
uat "clusters API answers" "got $code: 401/403 = token not accepted by kube-auth-proxy; 501 is expected until the console and backend gRPC names match" \
  bash -c "[[ $code == 200 || $code == 501 ]]"
[[ $code == 501 ]] && echo "     note: clusters API is 501 (Unimplemented): the known console/backend gRPC mismatch"
# The backend's own rights: label clusters, read the one root Policy, nothing more.
sa=system:serviceaccount:$ns:$name
can() { [[ $(kc $HOST auth can-i "$@" --as=$sa 2>/dev/null) == "$want" ]]; }
export -f can; export sa
uat "backend may label clusters" "ClusterRole ai-grid-provider-console-backend lacks patch (apps/console/manifests)" \
  bash -c "want=yes can patch managedclusters.cluster.open-cluster-management.io"
uat "backend can't create or delete clusters" "the backend's ClusterRole grew create or delete on managedclusters" \
  bash -c "want=no can create managedclusters.cluster.open-cluster-management.io && want=no can delete managedclusters.cluster.open-cluster-management.io"
uat "backend reads ai-grid-ready" "Role ai-grid-provider-console-backend in ai-grid-policies missing (apps/ai-grid-policies)" \
  bash -c "want=yes can get policies.policy.open-cluster-management.io/ai-grid-ready -n ai-grid-policies"
uat "backend can't read Policy copies" "the backend may read per-cluster Policies, whose hub templates hold rendered secrets" \
  bash -c "want=no can list policies.policy.open-cluster-management.io -A && want=no can get policies.policy.open-cluster-management.io -n local-cluster"
# patch also reaches spec, finalizers and other labels; an admission policy limits the backend to its own keys.
uat "backend may set only AI Grid labels" "ValidatingAdmissionPolicy ai-grid-provider-console-backend missing or not bound (apps/console/manifests)" \
  bash -c "! kc $HOST label managedcluster local-cluster ai-grid-verify/denied=true --dry-run=server --as=$sa >/dev/null 2>&1 \
    && ! kc $HOST patch managedcluster local-cluster --type=merge -p '{\"spec\":{\"leaseDurationSeconds\":61}}' --dry-run=server --as=$sa >/dev/null 2>&1 \
    && kc $HOST label managedcluster local-cluster ai-grid/verify=true --dry-run=server --as=$sa >/dev/null"
summary
