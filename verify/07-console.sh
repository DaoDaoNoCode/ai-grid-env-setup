#!/usr/bin/env bash
# The provider console on the hub (Task 9): signed in with the cluster's OpenShift login, its BFF
# reaching the backend, and the clusters API answering a provider admin.
source "$(dirname "$0")/lib.sh"
ns=ai-grid name=ai-grid-provider-console
host=$(kc $HOST get route $name -n $ns -o jsonpath='{.spec.host}' 2>/dev/null)
build_ok() { [[ $(kc $HOST get builds -n $ns -l buildconfig=$1 --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.phase}') == Complete ]]; }
export -f build_ok; export ns name
uat "app console"         "Argo CD app not Synced/Healthy: the console chart at its pinned commit, or the pod (secrets from bootstrap/60-console.sh)" app console
# The pod runs exactly the images git pins in apps/console/values.yaml (ghcr.io by default, the hub's
# registry as fallback), as the chart writes them: repository[:tag][@digest].
values="$(dirname "$0")/../apps/console/values.yaml"
# The image as the chart renders it: repository, then :tag and @digest when set and not empty (the
# chart's `if .tag`, `if .digest`). A missing tag key takes the chart's default, latest; a key set to
# null drops it, as Helm's value merge does. values.yaml names each repository: the chart's default
# repository isn't assumed here, so leaving one out fails "console runs the pinned images".
pin() {
  local r t d
  r=$(yq ".images.$1.repository" "$values")
  if [[ $(yq ".images.$1 | has(\"tag\")" "$values") == true ]]; then t=$(yq ".images.$1.tag // \"\"" "$values"); else t=latest; fi
  d=$(yq ".images.$1.digest // \"\"" "$values")
  echo "$r${t:+:$t}${d:+@$d}"
}
# Built on the hub (manifests/builds.yaml): the internal registry's exact address, not a prefix of it.
incluster() { [[ $(yq ".images.$1.repository" "$values") == image-registry.openshift-image-registry.svc:5000/* ]]; }
pinned=$(pin console; pin backend)
live=$(kc $HOST get deploy $name -n $ns -o json | jq -r '.spec.template.spec.containers[] | select(.name=="bff" or .name=="ai-grid-backend") | .image')
export -f pin incluster; export pinned live values
# Each image on its own: one built on the hub's registry doesn't excuse the other from a digest.
uat "console images pinned by digest" "an image in apps/console/values.yaml that isn't on the hub's registry lacks a digest: a tag alone can be overwritten" \
  bash -c 'for i in console backend; do incluster $i || [[ $(pin $i) == *@sha256:* ]] || exit 1; done'
uat "console runs the pinned images" "Argo CD app console not synced to git's image pins (apps/console/values.yaml), or the chart failed to render" \
  bash -c '[[ -n $pinned && $pinned == "$live" ]]'
incluster console && uat "console image built" "BuildConfig ai-grid-provider-console: oc logs -n $ns bc/ai-grid-provider-console" build_ok ai-grid-provider-console
incluster backend && uat "backend image built" "BuildConfig ai-grid-backend: oc logs -n $ns bc/ai-grid-backend" build_ok ai-grid-backend
if ! incluster console || ! incluster backend; then
  uat "console images pull" "ghcr.io package private (make it Public) or tag missing: kc host get pods -n $ns" \
    bash -c "! kc $HOST get pods -n $ns -l app.kubernetes.io/name=$name -o json | jq -e '[.items[].status.containerStatuses[]?.state.waiting.reason // empty] | map(select(test(\"ImagePull|ErrImage\"))) | length > 0' >/dev/null"
fi
uat "console pod ready"   "secrets missing (bootstrap/60-console.sh), or the BFF's /readyz can't ping the backend" \
  kc $HOST rollout status deploy/$name -n $ns --timeout=5s
# The backend authenticates no one (out of the MVP's scope, ai-grid-provider-backend#3) and acts as
# the console's ServiceAccount, so it must be reachable only through kube-auth-proxy and the BFF.
uat "backend REST on loopback" "the backend's REST gateway listens on the pod network without authentication" \
  bash -c "kc $HOST get deploy $name -n $ns -o json | jq -e '.spec.template.spec.containers[] | select(.name==\"ai-grid-backend\") | .args | index(\"--http-listen-address=127.0.0.1:8081\")'"
uat "backend API on loopback" "the backend's gRPC/Connect port listens on the pod network without authentication" \
  bash -c "kc $HOST get deploy $name -n $ns -o json | jq -e '.spec.template.spec.containers[] | select(.name==\"ai-grid-backend\") | .args | index(\"--listen-address=127.0.0.1:9090\")'"
uat "only the proxy is exposed" "Service $name exposes a port other than kube-auth-proxy's https: the BFF and the backend must stay behind the proxy" \
  bash -c "[[ \$(kc $HOST get svc $name -n $ns -o json | jq -c '[.spec.ports[].targetPort]') == '[\"https\"]' ]]"
uat "sign-in goes to OpenShift" "OAuthClient $name or Secret $name-oauth missing (bootstrap/60-console.sh)" \
  bash -c "curl -s -o /dev/null -w '%{redirect_url}' https://$host/ | grep -q '/oauth2/start\|oauth-openshift\|/oauth/authorize'"
uat "BFF reaches backend" "/readyz pings the backend over loopback; the backend container isn't serving" \
  bash -c "curl -s -o /dev/null -w '%{http_code}' https://$host/readyz | grep -qx 200"
# A signed-in provider admin's call: the token reaches curl through a file descriptor, never argv.
code=$(curl -s -o /dev/null -w '%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$(kc $HOST whoami -t)") "https://$host/api/v1/clusters")
uat "clusters API answers" "got $code: 401/403 = token not accepted by kube-auth-proxy or not a provider admin; 501 = console and backend images don't match" \
  bash -c "[[ $code == 200 ]]"
# The backend's own rights: label clusters, read the one root Policy and ACM Search, nothing more.
sa=system:serviceaccount:$ns:$name
can() { [[ $(kc $HOST auth can-i "$@" --as=$sa 2>/dev/null) == "$want" ]]; }
export -f can; export sa
uat "backend may label clusters" "ClusterRole ai-grid-provider-console-backend lacks patch (backend.clusterWrites in apps/console/values.yaml)" \
  bash -c "want=yes can patch managedclusters.cluster.open-cluster-management.io"
uat "backend can't create or delete clusters" "the backend's ClusterRole grew create or delete on managedclusters" \
  bash -c "want=no can create managedclusters.cluster.open-cluster-management.io && want=no can delete managedclusters.cluster.open-cluster-management.io"
uat "backend reads ai-grid-ready" "Role ai-grid-provider-console-backend in ai-grid-policies missing (apps/ai-grid-policies)" \
  bash -c "want=yes can get policies.policy.open-cluster-management.io/ai-grid-ready -n ai-grid-policies"
uat "backend reads ACM Search" "ClusterRoleBinding ai-grid-provider-console-search missing (apps/console/manifests/search-rbac.yaml): clusters show no GPU details" \
  bash -c "want=yes can get searches.search.open-cluster-management.io/allManagedData"
uat "backend can't read Policy copies" "the backend may read per-cluster Policies, whose hub templates hold rendered secrets" \
  bash -c "want=no can list policies.policy.open-cluster-management.io -A && want=no can get policies.policy.open-cluster-management.io -n local-cluster"
# patch also reaches spec, finalizers and other labels; an admission policy limits the backend to its own keys.
uat "backend may set only AI Grid labels" "ValidatingAdmissionPolicy ai-grid-provider-console-backend missing or not bound (backend.clusterWrites in apps/console/values.yaml)" \
  bash -c "! kc $HOST label managedcluster local-cluster ai-grid-verify/denied=true --dry-run=server --as=$sa >/dev/null 2>&1 \
    && ! kc $HOST patch managedcluster local-cluster --type=merge -p '{\"spec\":{\"leaseDurationSeconds\":61}}' --dry-run=server --as=$sa >/dev/null 2>&1 \
    && ! kc $HOST patch managedcluster local-cluster --type=merge -p '{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"name\":\"gone\",\"uid\":\"00000000-0000-0000-0000-000000000000\"}]}}' --dry-run=server --as=$sa >/dev/null 2>&1 \
    && kc $HOST label managedcluster local-cluster ai-grid/verify=true --dry-run=server --as=$sa >/dev/null"
summary
