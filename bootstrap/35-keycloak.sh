#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
ns=$KEYCLOAK_NS realm=ai-grid
# The realm imports read the tenant identity providers' public URL and broker client secrets from
# Secret ai-grid-tenant-idps. Argo CD creates the Route (wave 2) well before the imports (wave 3,
# after Keycloak is Ready), so the Secret exists in time. Secrets are made once and kept; they reach
# kubectl through a pipe, never argv.
wait_created $HOST route/maas-keycloak $ns 900
kchost=$(kc $HOST get route maas-keycloak -n $ns -o jsonpath='{.spec.host}')
if ! kc $HOST get secret ai-grid-tenant-idps -n $ns >/dev/null 2>&1; then
  URL=https://$kchost S1=$(openssl rand -hex 32) S2=$(openssl rand -hex 32) jq -n --arg ns "$ns" \
    '{apiVersion: "v1", kind: "Secret", metadata: {name: "ai-grid-tenant-idps", namespace: $ns},
      stringData: {"keycloak-url": env.URL, "org1-broker-secret": env.S1, "org2-broker-secret": env.S2}}' \
    | kc $HOST apply -f - >/dev/null
fi
for r in ai-grid org1-idp org2-idp; do
  wait_created $HOST keycloakrealmimport/$r $ns 900
  kc $HOST wait keycloakrealmimport/$r -n $ns --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True --timeout=15m
done
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
# The operator never re-imports a realm that exists, so a hub whose realm ai-grid predates the broker
# keeps its random organization IDs and has no identity providers. Stop with the upgrade steps.
want=$(yq '.spec.realm.organizations[] | select(.name == "org1") | .id' "$(dirname "$0")/../apps/keycloak/manifests/realm-ai-grid.yaml")
have=$(api "$base/organizations?search=org1&exact=true" | jq -r '.[0].id // ""')
if [[ $have != "$want" ]] || ! api "$base/identity-provider/instances/org1-idp" >/dev/null 2>&1; then
  die "realm $realm predates the broker (org1 is ${have:-missing}, want $want; or no identity provider org1-idp). Upgrade it (docs/runbook.md, \"Upgrading realm ai-grid to the broker\"): delete realm $realm, delete keycloakrealmimport/$realm -n $ns (Argo CD recreates it), then rerun bootstrap/35-keycloak.sh, 36-portal-clients.sh and 60-console.sh"
fi
# The realm import runs once, so apply brute-force protection (as in realm-ai-grid.yaml) to an
# existing realm too.
api "$base" | jq '.bruteForceProtected = true | .permanentLockout = false | .failureFactor = 10
  | .waitIncrementSeconds = 60 | .maxFailureWaitSeconds = 900' | api -X PUT "$base" -d @- >/dev/null
# Groups and the groups claim, as in realm-ai-grid.yaml, for a realm imported before them (the import runs
# once). Each organization's group <organization id> holds leaf groups that carry maas_groups
# (`<organization id>/<group>`), which scope maas emits as the groups claim. A leaf group named
# `<organization id>:<group>` from the earlier shape hands its members to the new one and is deleted.
realm_yaml="$(dirname "$0")/../apps/keycloak/manifests/realm-ai-grid.yaml"
[[ -f $realm_yaml ]] || die "$realm_yaml not found"
# group_id <path>: the group's ID, or nothing.
group_id() { api "$base/group-by-path/$1" 2>/dev/null | jq -r '.id // empty' || true; }
while read -r parent; do
  pid=$(group_id "$parent")
  [[ -n $pid ]] || { api -X POST "$base/groups" -d "$(jq -nc --arg n "$parent" '{name: $n}')" >/dev/null; pid=$(group_id "$parent"); }
  [[ -n $pid ]] || die "group $parent not created in realm $realm"
  while read -r child; do
    name=$(jq -r .name <<<"$child")
    cid=$(group_id "$parent/$name")
    if [[ -z $cid ]]; then
      api -X POST "$base/groups/$pid/children" -d "$child" >/dev/null; cid=$(group_id "$parent/$name")
      [[ -n $cid ]] || die "group /$parent/$name not created in realm $realm"
    else
      api "$base/groups/$cid" | jq --argjson c "$child" '.attributes = $c.attributes' | api -X PUT "$base/groups/$cid" -d @- >/dev/null
    fi
    old=$(api -G "$base/groups" --data-urlencode "search=$parent:$name" -d exact=true \
      | jq -r --arg n "$parent:$name" '.[] | select(.name == $n) | .id')
    if [[ -n $old ]]; then
      for m in $(api "$base/groups/$old/members?max=10000" | jq -r '.[].id'); do api -X PUT "$base/users/$m/groups/$cid" >/dev/null; done
      api -X DELETE "$base/groups/$old" >/dev/null
    fi
  done < <(yq -o=json -I=0 ".spec.realm.groups[] | select(.name == \"$parent\") | .subGroups[]" "$realm_yaml")
done < <(yq '.spec.realm.groups[].name' "$realm_yaml")
# Each identity provider mapper as in git (the group mappers name the groups above).
while read -r m; do
  alias=$(jq -r .identityProviderAlias <<<"$m"); name=$(jq -r .name <<<"$m")
  mid=$(api "$base/identity-provider/instances/$alias/mappers" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
  if [[ -n $mid ]]; then
    jq -c --arg id "$mid" '. + {id: $id}' <<<"$m" | api -X PUT "$base/identity-provider/instances/$alias/mappers/$mid" -d @- >/dev/null
  else
    api -X POST "$base/identity-provider/instances/$alias/mappers" -d "$m" >/dev/null
  fi
done < <(yq -o=json -I=0 '.spec.realm.identityProviderMappers[]' "$realm_yaml")
# Scope maas's groups mapper as in git; a mapper's type can't change in place, so replace it.
sid=$(api "$base/client-scopes" | jq -r '.[] | select(.name == "maas") | .id')
[[ -n $sid ]] || die "client scope maas not found in realm $realm"
want_gm=$(yq -o=json -I=0 '.spec.realm.clientScopes[] | select(.name == "maas") | .protocolMappers[] | select(.name == "groups")' "$realm_yaml")
have_gm=$(api "$base/client-scopes/$sid/protocol-mappers/models" | jq -c '.[] | select(.name == "groups")')
if [[ -z $have_gm ]] || ! jq -e --argjson w "$want_gm" '. as $h | .protocolMapper == $w.protocolMapper and ($w.config | to_entries | all($h.config[.key] == .value))' <<<"$have_gm" >/dev/null; then
  [[ -z $have_gm ]] || api -X DELETE "$base/client-scopes/$sid/protocol-mappers/models/$(jq -r .id <<<"$have_gm")" >/dev/null
  api -X POST "$base/client-scopes/$sid/protocol-mappers/models" -d "$want_gm" >/dev/null
fi
# The realm import doesn't apply a user profile, and the default profile drops unknown
# attributes: let admins set unmanaged ones such as maas_orgs (feeds the MaaS organization claim).
api "$base/users/profile" | jq '.unmanagedAttributePolicy = "ADMIN_EDIT"' | api -X PUT "$base/users/profile" -d @- >/dev/null
# Only an admin edits a user's email (a realm import can't set the user profile). In the tenant realms the
# broker copies it in on every sign-in; in the broker realm a local user who set another organization's
# address would block that person's first brokered sign-in (no account linking, so a duplicate email fails).
for r in org1-idp org2-idp ai-grid; do
  api "https://$kchost/admin/realms/$r/users/profile" | jq '(.attributes[] | select(.name == "email") | .permissions.edit) = ["admin"]' \
    | api -X PUT "https://$kchost/admin/realms/$r/users/profile" -d @- >/dev/null
done
# The realm import runs once, and listing clientScopes replaced Keycloak's built-in ones, so make
# sure scope maas carries sub, email, and preferred_username (MaaS's user name; email for the portal's
# sign-in proxy) on an existing realm too.
msid=$(api "$base/client-scopes" | jq -r '.[] | select(.name=="maas") | .id')
have=$(api "$base/client-scopes/$msid/protocol-mappers/models" | jq -r '.[].name')
grep -qx sub <<<"$have" || api -X POST "$base/client-scopes/$msid/protocol-mappers/models" -d '{"name":"sub","protocol":"openid-connect","protocolMapper":"oidc-sub-mapper","config":{"access.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
grep -qx email <<<"$have" || api -X POST "$base/client-scopes/$msid/protocol-mappers/models" -d '{"name":"email","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"email","claim.name":"email","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' >/dev/null
grep -qx username <<<"$have" || api -X POST "$base/client-scopes/$msid/protocol-mappers/models" -d '{"name":"username","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"username","claim.name":"preferred_username","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' >/dev/null
kc $HOST get secret ai-grid-test-users -n $ns >/dev/null 2>&1 || kc $HOST create secret generic ai-grid-test-users -n $ns >/dev/null
# upsert_user <realm> <user> <email> <last name> <password key> <attributes JSON>: creates or updates a
# user with a password kept in Secret ai-grid-test-users under <password key>; prints the user's ID.
# It runs in $(...), where errexit is off, so each step checks its own result.
upsert_user() {
  local r=$1 u=$2 email=$3 last=$4 key=$5 attrs=$6 id pw body
  id=$(api "https://$kchost/admin/realms/$r/users?username=$u&exact=true" | jq -r '.[0].id // empty')
  pw=$(kc $HOST get secret ai-grid-test-users -n $ns -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d)
  pw=${pw:-$(openssl rand -base64 18)}
  body=$(PW=$pw jq -n --arg u "$u" --arg email "$email" --arg last "$last" --argjson attrs "$attrs" '{username: $u,
    enabled: true, emailVerified: true, email: $email, firstName: $u, lastName: $last, attributes: $attrs,
    credentials: [{ type: "password", value: env.PW, temporary: false }] }')
  # The body holds the password: it goes on stdin, not argv.
  if [[ -z $id ]]; then printf %s "$body" | api -X POST "https://$kchost/admin/realms/$r/users" --data-binary @- >/dev/null || return 1
    id=$(api "https://$kchost/admin/realms/$r/users?username=$u&exact=true" | jq -r '.[0].id')
  else printf %s "$body" | api -X PUT "https://$kchost/admin/realms/$r/users/$id" --data-binary @- >/dev/null || return 1; fi
  [[ -n $id && $id != null ]] || return 1
  # The password reaches kubectl through the environment and a pipe, never argv.
  B64=$(printf '%s' "$pw" | base64 | tr -d '\n') jq -n --arg k "$key" '{data: {($k): env.B64}}' \
    | kc $HOST patch secret ai-grid-test-users -n $ns --type merge --patch-file /dev/stdin >/dev/null || return 1
  echo "$id"
}
# add_group <realm> <user id> <group path>
add_group() {
  local gid
  gid=$(api "https://$kchost/admin/realms/$1/group-by-path/$3" 2>/dev/null | jq -r '.id // empty' || true)
  [[ -n $gid ]] || die "group $3 not found in realm $1"
  api -X PUT "https://$kchost/admin/realms/$1/users/$2/groups/$gid" >/dev/null
}
# Local users of the broker realm, for the CLI and verify (password grant): unmanaged members of their
# organization, with email addresses outside every organization's domain, so a brokered user never
# matches one. Group <name> is the realm's group <name> under group <organization id>; "-" = no group, so in no
# subscription.
while read -r u org grp; do
  oid=$(api "$base/organizations?search=$org&exact=true" | jq -re '.[0].id') || die "organization $org not found in realm $realm"   # a UUID, which MaaS requires
  id=$(upsert_user $realm "$u" "$u@users.example.net" "$org" "$u" \
    "$(jq -nc --arg org "$org" --arg oid "$oid" '{maas_orgs: [([{organization_id: $oid, organization_name: $org, roles: ["member"]}] | tojson)]}')") \
    || die "user $u in realm $realm not set up"
  api -X POST "$base/organizations/$oid/members" -d "\"$id\"" >/dev/null 2>&1 || true   # 409 when already a member
  [[ $grp == - ]] || add_group $realm "$id" "$oid/$grp"
done <<'USERS'
alice org1 group1
dave org1 -
bob org2 group1
USERS
# Users of the organizations' own identity providers, who sign in to the broker through them (browser
# only). Their email domain is their organization's, which Keycloak requires of a managed member.
while read -r r u org grp; do
  id=$(upsert_user $r "$u" "$u@$org.example.com" "$org" "$r-$u" '{}') || die "user $u in realm $r not set up"
  [[ $grp == - ]] || add_group $r "$id" "$grp"
done <<'USERS'
org1-idp alice org1 group1
org1-idp dave org1 -
org2-idp bob org2 group1
USERS
unset tok
kc $HOST create configmap ai-grid-hub-info -n ai-grid-policies --dry-run=client -o yaml | kc $HOST apply -f - >/dev/null
kc $HOST patch configmap ai-grid-hub-info -n ai-grid-policies --type merge -p "{\"data\":{
  \"keycloakHost\":\"$kchost\",\"tenantIssuer\":\"https://$kchost/realms/$realm\",\"tenantClientId\":\"maas-cli\"}}"
