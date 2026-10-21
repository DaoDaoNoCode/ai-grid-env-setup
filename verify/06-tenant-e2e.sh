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
  tok=$(printf %s "$pw" | curl -s -d grant_type=password -d client_id=maas-cli -d scope=openid --data-urlencode "username=$TENANT_USER" \
    --data-urlencode password@- "https://$KC/realms/ai-grid/protocol/openid-connect/token" | jq -r .access_token); unset pw
  TOKEN=$tok
  MODELS=$(curl -s -H @<(bearer "$tok") "$MAAS/maas-api/v1/models")
  KEY=$(curl -s -X POST -H @<(bearer "$tok") -H 'Content-Type: application/json' \
    -d '{"name":"aigrid-e2e","expiresIn":"1d"}' "$MAAS/maas-api/v1/api-keys" | jq -r .key)
  URL="$MAAS/models-as-a-service/$MODEL_NAME"
}
# MaaS routes by its own model ID (the MaaSModelRef name), not the upstream name facebook/opt-125m.
e2e_complete() {
  curl -s -D out/e2e-completion.headers -o out/e2e-completion.json -w '%{http_code}' -H @<(bearer "$KEY") -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":$1}" "$URL/v1/chat/completions"
}
[[ -n "${E2E_LIB:-}" ]] && return 0   # sourced as a library: define functions only
mkdir -p out
e2e_login
export -f bearer; export TOKEN
uat "keycloak token"  "Keycloak route or test user (Task 3's checks)" test -n "$TOKEN" -a "$TOKEN" != null
uat "MaaS trusts the token" "AITenant oidc not set on $E2E_SPOKE (Policy tenant-oidc), or the issuer differs from Keycloak's" \
  bash -c "curl -s -o /dev/null -w '%{http_code}' -H @<(bearer \"\$TOKEN\") $MAAS/maas-api/v1/models | grep -qx 200"
uat "model listed"    "token valid but no subscription matches the user's groups (Review focus 4)" \
  jq -e '.data[]|select(.id=="facebook/opt-125m" or .id=="'"$MODEL_NAME"'")' <<<"$MODELS"
uat "model URL is public" "MaaS listed an in-cluster address: the gateway listener has no host name (Policy maas-route sets it on the spoke)" \
  jq -e --arg m "$MAAS" '[.data[]|select(.id=="'"$MODEL_NAME"'")|.url|startswith($m)]|any' <<<"$MODELS"
uat "api key minted"  "maas-api can't write keys: its database (Policy maas-db) or maas-api logs" test -n "$KEY" -a "$KEY" != null
code=$(e2e_complete 8)
uat "completion 200"  "got $code: 401/403 = key or subscription; 404/503 = MaaS can't reach grid-gateway.$GRID_NS.svc, or the grid has no healthy site; 400 = opt-125m chat template (Task 7, Step 2)" \
  test "$code" = 200
uat "completion text" "200 without content: the grid answered but vLLM returned nothing" jq -e '.choices[0].message.content | length > 0' out/e2e-completion.json
# Which site served it: the provider gateway sets X-Grid-Provider-Site. Opt-in (E2E_EXPECT_SITE=<site>),
# because whether MaaS passes the header back is unverified. For an inference split, name the
# inference site. Stopping only the entry spoke's model doesn't move traffic (the consumer
# health-checks provider gateways over TCP, so that site keeps being chosen and answers 502): the proof
# needs a model only the inference site serves, or the entry spoke's provider stopped (unverified that
# intelligent_route then skips it). Pending which of the two (runbook, inference site, step 5).
if [[ -n ${E2E_EXPECT_SITE:-} ]]; then
  uat "served by $E2E_EXPECT_SITE" "another site served it (or MaaS dropped X-Grid-Provider-Site): grep -i x-grid out/e2e-completion.headers; on a refusal, siteDigests or consumerSites" \
    bash -c "tr -d '\r' <out/e2e-completion.headers | grep -iqx 'x-grid-provider-site: $E2E_EXPECT_SITE'"
fi
unset TOKEN KEY
summary
