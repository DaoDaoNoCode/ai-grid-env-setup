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
uat "console image built" "BuildConfig ai-grid-provider-console: oc logs -n $ns bc/ai-grid-provider-console" build_ok ai-grid-provider-console
uat "backend image built" "BuildConfig ai-grid-backend: oc logs -n $ns bc/ai-grid-backend" build_ok ai-grid-backend
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
summary
