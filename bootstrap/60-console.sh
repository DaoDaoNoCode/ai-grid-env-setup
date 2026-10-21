#!/usr/bin/env bash
# What the console needs that isn't in git (Task 9): its OpenShift OAuthClient and proxy Secret
# (provider admins sign in with their cluster login), and the backend's Keycloak credentials. The
# backend gets its own user in realm ai-grid with only the realm-management roles organizations need,
# not the master realm's admin. Run after Argo CD has synced app console. Safe to rerun.
source "$(dirname "$0")/lib.sh"
ns=ai-grid name=ai-grid-provider-console realm=ai-grid kuser=ai-grid-console-backend
kchost=$(kc $HOST get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.keycloakHost}')
[[ -n $kchost ]] || die "run bootstrap/35-keycloak.sh first"
for _ in $(seq 1 60); do host=$(kc $HOST get route $name -n $ns -o jsonpath='{.spec.host}' 2>/dev/null) && [[ -n $host ]] && break; sleep 10; done
[[ -n ${host:-} ]] || die "route $name in $ns missing: is Argo CD app console synced?"

# Keycloak: a backend user that may manage users and organizations in realm ai-grid only.
au=$(kc $HOST get secret maas-keycloak-initial-admin -n $KEYCLOAK_NS -o jsonpath='{.data.username}' | base64 -d)
ap=$(kc $HOST get secret maas-keycloak-initial-admin -n $KEYCLOAK_NS -o jsonpath='{.data.password}' | base64 -d)
tok=$(printf %s "$ap" | curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$au" \
  --data-urlencode password@- "https://$kchost/realms/master/protocol/openid-connect/token" | jq -r .access_token); unset ap
[[ -n $tok && $tok != null ]] || die "Keycloak admin login failed"
api() { curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$tok") -H 'Content-Type: application/json' "$@"; }
base="https://$kchost/admin/realms/$realm"
uid=$(api "$base/users?username=$kuser&exact=true" | jq -r '.[0].id // empty')
if [[ -z $uid ]]; then
  jq -n --arg u "$kuser" '{username:$u, enabled:true, emailVerified:true, firstName:"AI Grid", lastName:"console backend", email:"\($u)@ai-grid.invalid"}' \
    | api -X POST "$base/users" -d @- >/dev/null
  uid=$(api "$base/users?username=$kuser&exact=true" | jq -re '.[0].id')
fi
pw=$(kc $HOST get secret ai-grid-backend-keycloak -n $ns -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
pw=${pw:-$(openssl rand -base64 24)}
PW=$pw jq -n '{type:"password", value:env.PW, temporary:false}' | api -X PUT "$base/users/$uid/reset-password" -d @- >/dev/null
rm_id=$(api "$base/clients?clientId=realm-management" | jq -re '.[0].id')
api "$base/clients/$rm_id/roles" | jq '[.[] | select(.name | IN("view-users","query-users","manage-users","view-realm","manage-realm"))]' \
  | api -X POST "$base/users/$uid/role-mappings/clients/$rm_id" -d @- >/dev/null
PW=$pw jq -n --arg url "https://$kchost" --arg realm $realm --arg user $kuser '{apiVersion:"v1", kind:"Secret",
  metadata:{name:"ai-grid-backend-keycloak", namespace:"ai-grid"}, type:"Opaque",
  stringData:{url:$url, realm:$realm, "admin-realm":$realm, username:$user, password:env.PW}}' | kc $HOST apply -f - >/dev/null
unset pw

# OpenShift login for provider admins: an OAuthClient and the proxy's Secret, kept across reruns.
redirect="https://$host/oauth2/callback"
cs=$(kc $HOST get secret $name-oauth -n $ns -o jsonpath='{.data.OAUTH2_PROXY_CLIENT_SECRET}' 2>/dev/null | base64 -d || true)
ck=$(kc $HOST get secret $name-oauth -n $ns -o jsonpath='{.data.OAUTH2_PROXY_COOKIE_SECRET}' 2>/dev/null | base64 -d || true)
# kube-auth-proxy takes the cookie secret as raw bytes (16, 24 or 32), not base64.
[[ ${#ck} == 32 ]] || ck=""
CS=${cs:-$(openssl rand -hex 32)} CK=${ck:-$(openssl rand -hex 16)}
CS=$CS jq -n --arg n $name --arg r "$redirect" '{apiVersion:"oauth.openshift.io/v1", kind:"OAuthClient",
  metadata:{name:$n}, grantMethod:"auto", redirectURIs:[$r], secret:env.CS}' | kc $HOST apply -f - >/dev/null
CS=$CS CK=$CK jq -n --arg n $name --arg r "$redirect" '{apiVersion:"v1", kind:"Secret",
  metadata:{name:"\($n)-oauth", namespace:"ai-grid"}, type:"Opaque",
  stringData:{OAUTH2_PROXY_CLIENT_ID:$n, OAUTH2_PROXY_CLIENT_SECRET:env.CS, OAUTH2_PROXY_COOKIE_SECRET:env.CK, OAUTH2_PROXY_REDIRECT_URL:$r}}' \
  | kc $HOST apply -f - >/dev/null
unset cs ck CS CK
kc $HOST rollout restart deploy/$name -n $ns >/dev/null
log "console: https://<route ai-grid-provider-console in ai-grid>; sign in with an OpenShift login that may patch managedclusters"
