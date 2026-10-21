#!/usr/bin/env bash
# MaaS accepts tokens from one client per tenant (AITenant oidc.clientId, matched against azp), so the
# MaaS Portal's sign-in proxy (Policy tenant-portal) signs tenants in with the same public client the
# CLI uses, maas-cli, through the browser flow with PKCE: no client secret exists to hand out. This
# script adds every ingress spoke's portal callback to maas-cli's redirect URIs. Tenant logins never
# touch a cluster's OpenShift login. Its tokens last 1 hour, the portal session's length: the proxy
# can't hand a refreshed session back to the browser, because Authorino asks it on the browser's
# behalf. Rerun after adding an ingress spoke (Task 11).
source "$(dirname "$0")/lib.sh"
ns=$KEYCLOAK_NS realm=ai-grid cid=maas-cli
kchost=$(kc $HOST get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.keycloakHost}')
[[ -n $kchost ]] || die "run bootstrap/35-keycloak.sh first"
au=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.username}' | base64 -d)
ap=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.password}' | base64 -d)
# Secrets reach curl through a pipe or a file descriptor, never argv (where ps shows them).
tok=$(printf %s "$ap" | curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$au" \
  --data-urlencode password@- "https://$kchost/realms/master/protocol/openid-connect/token" | jq -r .access_token); unset ap
[[ -n $tok && $tok != null ]] || die "Keycloak admin login failed"
api() { curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$tok") -H 'Content-Type: application/json' "$@"; }
base="https://$kchost/admin/realms/$realm"
uris=()
for s in $SPOKES; do
  [[ $(role_of $s) == inference ]] && continue
  domain=$(kc $s get ingresses.config cluster -o jsonpath='{.spec.domain}')
  uris+=("https://maas.$domain/oauth2/callback")
done
id=$(api "$base/clients?clientId=$cid" | jq -re '.[0].id') || die "client $cid missing: realm ai-grid not imported (bootstrap/35-keycloak.sh)"
api "$base/clients/$id" | jq '.standardFlowEnabled = true | .redirectUris = $ARGS.positional
  | .attributes["pkce.code.challenge.method"] = "S256" | .attributes["access.token.lifespan"] = "3600"' --args "${uris[@]}" \
  | api -X PUT "$base/clients/$id" -d @- >/dev/null
# Earlier designs (a cluster-login identity provider per spoke, then a confidential maas-portal
# client) are gone: remove their clients and hub Secrets.
for old in $(api "$base/clients" | jq -r '.[] | select((.clientId|startswith("ocp-")) or .clientId == "maas-portal") | .id'); do
  api -X DELETE "$base/clients/$old" >/dev/null
done
for sname in $(kc $HOST get secret -n ai-grid-policies -o name | grep -E '/(portal-idp-|maas-portal-oidc$)'); do kc $HOST delete -n ai-grid-policies "$sname" >/dev/null; done
unset tok
log "client $cid takes the portal callback of ${#uris[@]} ingress spoke(s)"
