#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
ns=$KEYCLOAK_NS realm=ai-grid
kc $HOST wait keycloakrealmimport/ai-grid -n $ns --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True --timeout=15m
kchost=$(kc $HOST get route maas-keycloak -n $ns -o jsonpath='{.spec.host}')
# Pin Keycloak's hostname to the Route's host, so links and the issuer never come from request
# headers. Set here, not in git, to keep the host name out of the repository; Argo CD doesn't
# manage this field, so it doesn't revert it.
if [[ $(kc $HOST get keycloak maas-keycloak -n $ns -o jsonpath='{.spec.hostname.hostname}') != "https://$kchost" ]]; then
  kc $HOST patch keycloak maas-keycloak -n $ns --type merge -p "{\"spec\":{\"hostname\":{\"hostname\":\"https://$kchost\"}}}"
  kc $HOST wait keycloak/maas-keycloak -n $ns --for=condition=Ready --timeout=10m
fi
# Ready can be reported before a restarted pod serves; wait until the realm answers.
for _ in $(seq 1 60); do curl -fsS -o /dev/null "https://$kchost/realms/$realm/.well-known/openid-configuration" && break; sleep 10; done
au=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.username}' | base64 -d)
ap=$(kc $HOST get secret maas-keycloak-initial-admin -n $ns -o jsonpath='{.data.password}' | base64 -d)
# Secrets reach curl through a pipe or a file descriptor, never argv (where ps shows them).
tok=$(printf %s "$ap" | curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$au" \
  --data-urlencode password@- "https://$kchost/realms/master/protocol/openid-connect/token" | jq -r .access_token); unset ap
[[ -n $tok && $tok != null ]] || die "Keycloak admin login failed"
api() { curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$tok") -H 'Content-Type: application/json' "$@"; }
base="https://$kchost/admin/realms/$realm"
# The realm import doesn't apply a user profile, and the default profile drops unknown
# attributes: let admins set unmanaged ones such as maas_orgs (feeds the MaaS organization claim).
api "$base/users/profile" | jq '.unmanagedAttributePolicy = "ADMIN_EDIT"' | api -X PUT "$base/users/profile" -d @- >/dev/null
# The realm import runs once, and listing clientScopes replaced Keycloak's built-in ones, so make
# sure scope maas carries sub, email, and preferred_username (MaaS's user name; email for the portal's
# sign-in proxy) on an existing realm too.
msid=$(api "$base/client-scopes" | jq -r '.[] | select(.name=="maas") | .id')
have=$(api "$base/client-scopes/$msid/protocol-mappers/models" | jq -r '.[].name')
grep -qx sub <<<"$have" || api -X POST "$base/client-scopes/$msid/protocol-mappers/models" -d '{"name":"sub","protocol":"openid-connect","protocolMapper":"oidc-sub-mapper","config":{"access.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
grep -qx email <<<"$have" || api -X POST "$base/client-scopes/$msid/protocol-mappers/models" -d '{"name":"email","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"email","claim.name":"email","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' >/dev/null
grep -qx username <<<"$have" || api -X POST "$base/client-scopes/$msid/protocol-mappers/models" -d '{"name":"username","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"username","claim.name":"preferred_username","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' >/dev/null
kc $HOST get secret ai-grid-test-users -n $ns >/dev/null 2>&1 || kc $HOST create secret generic ai-grid-test-users -n $ns >/dev/null
# user org group ("-" = no group, so in no subscription)
while read -r u org grp; do
  id=$(api "$base/users?username=$u&exact=true" | jq -r '.[0].id // empty')
  pw=$(kc $HOST get secret ai-grid-test-users -n $ns -o jsonpath="{.data.$u}" 2>/dev/null | base64 -d)
  pw=${pw:-$(openssl rand -base64 18)}
  oid=$(api "$base/organizations?search=$org&exact=true" | jq -re '.[0].id') || die "organization $org not found in realm $realm"   # a UUID, which MaaS requires
  body=$(PW=$pw jq -n --arg u "$u" --arg org "$org" --arg oid "$oid" '{username: $u, enabled: true, emailVerified: true,
    email: ($u + "@" + $org + ".example.com"), firstName: $u, lastName: $org,
    attributes: { maas_orgs: [([{organization_id: $oid, organization_name: $org, roles: ["member"]}] | tojson)] },
    credentials: [{ type: "password", value: env.PW, temporary: false }] }')
  if [[ -z $id ]]; then api -X POST "$base/users" -d "$body" >/dev/null; id=$(api "$base/users?username=$u&exact=true" | jq -r '.[0].id')
  else api -X PUT "$base/users/$id" -d "$body" >/dev/null; fi
  api -X POST "$base/organizations/$oid/members" -d "\"$id\"" >/dev/null 2>&1 || true   # 409 when already a member
  if [[ -n $grp && $grp != - ]]; then
    gid=$(api "$base/groups?search=$grp&exact=true" | jq -r --arg g "$grp" '.[] | select(.name==$g) | .id')
    api -X PUT "$base/users/$id/groups/$gid" >/dev/null
  fi
  # The password reaches kubectl through the environment and a pipe, never argv.
  B64=$(printf '%s' "$pw" | base64 | tr -d '\n') jq -n --arg u "$u" '{data: {($u): env.B64}}' \
    | kc $HOST patch secret ai-grid-test-users -n $ns --type merge --patch-file /dev/stdin >/dev/null
  unset pw body
done <<'USERS'
alice org1 org1-group1
dave org1 -
bob org2 org2-group1
USERS
unset tok
kc $HOST create configmap ai-grid-hub-info -n ai-grid-policies --dry-run=client -o yaml | kc $HOST apply -f - >/dev/null
kc $HOST patch configmap ai-grid-hub-info -n ai-grid-policies --type merge -p "{\"data\":{
  \"keycloakHost\":\"$kchost\",\"tenantIssuer\":\"https://$kchost/realms/$realm\",\"tenantClientId\":\"maas-cli\"}}"
