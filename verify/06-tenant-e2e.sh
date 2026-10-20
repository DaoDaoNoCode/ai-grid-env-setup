#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
E2E_SPOKE=${E2E_SPOKE:-$(for s in $SPOKES; do [[ $(role_of $s) != inference ]] && { echo $s; break; }; done)}
KC=$(kc $HOST get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.keycloakHost}')
MAAS=$(maas_url $E2E_SPOKE)
TENANT_USER=${TENANT_USER:-alice}
bearer() { printf 'Authorization: Bearer %s\n' "$1"; }
e2e_login() {
  local pw tok
  pw=$(kc $HOST get secret ai-grid-test-users -n $KEYCLOAK_NS -o jsonpath="{.data.$TENANT_USER}" | base64 -d)
  # Secrets reach curl through a pipe or a file descriptor, never argv.
  tok=$(printf %s "$pw" | curl -sk -d grant_type=password -d client_id=maas-cli -d scope=openid --data-urlencode "username=$TENANT_USER" \
    --data-urlencode password@- "https://$KC/realms/ai-grid/protocol/openid-connect/token" | jq -r .access_token); unset pw
  TOKEN=$tok
  MODELS=$(curl -sk -H @<(bearer "$tok") "$MAAS/maas-api/v1/models")
  KEY=$(curl -sk -X POST -H @<(bearer "$tok") -H 'Content-Type: application/json' \
    -d '{"name":"aigrid-e2e","expiresIn":"1d"}' "$MAAS/maas-api/v1/api-keys" | jq -r .key)
  URL="$MAAS/models-as-a-service/$MODEL_NAME"
}
# MaaS routes by its own model ID (the MaaSModelRef name), not the upstream name facebook/opt-125m.
e2e_complete() {
  curl -sk -o out/e2e-completion.json -w '%{http_code}' -H @<(bearer "$KEY") -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":$1}" "$URL/v1/chat/completions"
}
[[ -n "${E2E_LIB:-}" ]] && return 0   # sourced as a library: define functions only
mkdir -p out
e2e_login
export -f bearer; export TOKEN
uat "keycloak token"  "Keycloak route or test user (Task 3's checks)" test -n "$TOKEN" -a "$TOKEN" != null
uat "MaaS trusts the token" "AITenant oidc not set on $E2E_SPOKE (Policy tenant-oidc), or the issuer differs from Keycloak's" \
  bash -c "curl -sk -o /dev/null -w '%{http_code}' -H @<(bearer \"\$TOKEN\") $MAAS/maas-api/v1/models | grep -qx 200"
uat "model listed"    "token valid but no subscription matches the user's groups (Review focus 4)" \
  jq -e '.data[]|select(.id=="facebook/opt-125m" or .id=="'"$MODEL_NAME"'")' <<<"$MODELS"
uat "model URL is public" "MaaS listed an in-cluster address: the gateway listener has no host name (Policy maas-route sets it on the spoke)" \
  jq -e --arg m "$MAAS" '[.data[]|select(.id=="'"$MODEL_NAME"'")|.url|startswith($m)]|any' <<<"$MODELS"
uat "api key minted"  "maas-api can't write keys: its database (Policy maas-db) or maas-api logs" test -n "$KEY" -a "$KEY" != null
code=$(e2e_complete 8)
uat "completion 200"  "got $code: 401/403 = key or subscription; 404/503 = MaaS can't reach grid-gateway.$GRID_NS.svc, or the grid has no healthy site; 400 = opt-125m chat template (Task 7, Step 2)" \
  test "$code" = 200
uat "completion text" "200 without content: the grid answered but vLLM returned nothing" jq -e '.choices[0].message.content | length > 0' out/e2e-completion.json
unset TOKEN KEY
summary
