#!/usr/bin/env bash
# A tenant's browser walk into the MaaS Portal, with curl and a cookie jar: the portal sends an
# unsigned-in visitor to the hub's Keycloak (realm ai-grid), the user signs in, and the portal opens
# with their identity. The cluster's own OpenShift login must stay untouched.
source "$(dirname "$0")/lib.sh"
PORTAL_SPOKE=${PORTAL_SPOKE:-$(for s in $SPOKES; do [[ $(role_of $s) != inference ]] && { echo $s; break; }; done)}
TENANT_USER=${TENANT_USER:-alice}
MAAS=$(maas_url $PORTAL_SPOKE)
KC=$(kc $HOST get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.keycloakHost}')
jar=${PORTAL_JAR:-$(mktemp -d)}; [[ -n ${PORTAL_JAR:-} ]] || trap 'rm -rf "$jar"' EXIT
# loc <curl args...>: the response's Location header, following nothing.
loc() { curl -s -o /dev/null -w '%{redirect_url}' -b "$jar/c" -c "$jar/c" "$@"; }

uat "policy tenant-portal" "template error or still inform: kc host get policy ai-grid-policies.tenant-portal -n $PORTAL_SPOKE -o yaml" pol $PORTAL_SPOKE tenant-portal
uat "sign-in proxy ready"  "image pull, or Secret maas-portal-proxy missing a key: kc $PORTAL_SPOKE logs deploy/maas-portal-proxy -n aigrid-portal-auth" \
  kc $PORTAL_SPOKE rollout status deploy/maas-portal-proxy -n aigrid-portal-auth --timeout=5s
uat "OpenShift login untouched" "an identity provider other than the demo's rhbk was added to the cluster's OAuth" \
  bash -c "kc $PORTAL_SPOKE get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | grep -qx rhbk"
# A browser reuses an HTTP/2 connection for any host its certificate covers at the same address, so
# a wildcard here would send Keycloak and console requests to the MaaS gateway, which answers 404.
host=${MAAS#https://}
uat "gateway certificate names only maas" "the MaaS gateway serves a certificate covering other hosts (Policy maas-route's Certificate maas-gw-public-tls not issued yet?)" \
  bash -c "echo | openssl s_client -connect $host:443 -servername $host 2>/dev/null | openssl x509 -noout -ext subjectAltName | tr -d ' ' | grep -qx 'DNS:$host'"

start=$(loc "$MAAS/maas-consumer-portal/")
uat "visitor sent to sign in" "AuthPolicy maas-portal-oidc not enforced, or the route isn't attached (gateway allowedRoutes lacks aigrid-portal-auth); got '$start'" \
  bash -c "[[ '$start' == '$MAAS/oauth2/start?rd='* ]]"
kcauth=$(loc "$start")
uat "proxy sends to Keycloak" "proxy can't read the issuer's discovery document, or route maas-portal-signin isn't public; got '${kcauth%%\?*}'" \
  bash -c "[[ '$kcauth' == 'https://$KC/realms/ai-grid/protocol/openid-connect/auth?'* ]]"
# formurl <file>: the first form's action URL in a Keycloak page.
formurl() { grep -o 'action="[^"]*"' "$1" | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g'; }
curl -s -b "$jar/c" -c "$jar/c" -o "$jar/login" "$kcauth"; form=$(formurl "$jar/login")
uat "Keycloak login page" "client maas-cli rejects the redirect URI: rerun bootstrap/36-portal-clients.sh" test -n "$form"
# A realm with organizations asks for the user name first, then the password on a second page.
curl -s -b "$jar/c" -c "$jar/c" -o "$jar/login" --data-urlencode "username=$TENANT_USER" "$form"; form=$(formurl "$jar/login")
# The password reaches curl through the environment and a pipe, never argv.
callback=$(PW=$(kc $HOST get secret ai-grid-test-users -n $KEYCLOAK_NS -o jsonpath="{.data.$TENANT_USER}" | base64 -d) \
  jq -jn --arg u "$TENANT_USER" '"username=\($u|@uri)&password=\(env.PW|@uri)"' | loc --data-binary @- "$form")
uat "$TENANT_USER signs in" "wrong password in keycloak/ai-grid-test-users, or the login failed; no callback returned" \
  bash -c "[[ '$callback' == '$MAAS/oauth2/callback?'* ]]"
back=$(loc "$callback")
uat "session started" "proxy refused the code: PKCE not enabled on maas-cli, or a missing email claim; see the proxy's log" \
  bash -c "[[ '$back' == '/maas-consumer-portal/' || '$back' == '$MAAS/maas-consumer-portal/' ]] && grep -q __Host-maas_portal_proxy '$jar/c'"
# A __Host- cookie carries no Domain, so no other host (a subdomain of maas.<domain>) can set or
# shadow it; curl's jar marks a cookie with a Domain by a leading dot and TRUE.
uat "session cookie host-only" "the proxy sets a Domain on its cookie, or isn't named __Host-maas_portal_proxy (--cookie-name, no --cookie-domain)" \
  bash -c "awk -F'\t' '\$6 ~ /^__Host-maas_portal_proxy/ && \$1 !~ /^(#HttpOnly_)?\\./ && \$2 == \"FALSE\" {f=1} END {exit !f}' '$jar/c'"
# Only the sign-in steps are public; /oauth2/auth would hand a page's script the session's token.
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar/c" "$MAAS/oauth2/auth")
uat "proxy's token endpoint not public" "got $code: an old route maas-portal-oauth2 (all of /oauth2) is still attached, or maas-portal-signin matches more than start, callback and sign_out" \
  bash -c "[[ $code != 2* ]]"
code=$(curl -s -o "$jar/page" -w '%{http_code}' -b "$jar/c" "$MAAS/maas-consumer-portal/")
uat "portal opens" "got $code: 302 = Authorino can't reach the proxy's /oauth2/auth; 503 = gateway can't reach maas-portal (ReferenceGrant, DestinationRule, or its NetworkPolicy)" \
  bash -c "[[ $code == 200 ]] && grep -qi '<html' '$jar/page'"
# The portal's MaaS module receives alice's token and lists her models.
code=$(curl -s -o "$jar/models" -w '%{http_code}' -b "$jar/c" "$MAAS/maas-consumer-portal/maas/api/v1/models")
uat "portal lists alice's models" "got $code: 401/403/302 = the session's token wasn't passed on (AuthPolicy maas-portal-oidc); 503 'maas-api is not available' = MaaS can't name its public URL (listener host name, Policy maas-route), or maas-ui cached a failed lookup (restart it)" \
  bash -c "[[ $code == 200 ]] && jq -e '[.. | strings] | index(\"$MODEL_NAME\")' '$jar/models'"
# Cross-origin writes: a page on another host under the same apps domain is same-site, so the lax
# session cookie rides along. The gateway must refuse a cookie-session write whose Origin isn't the
# portal's own, and still let the portal's own writes through. POST to a read-only path: the portal
# answers 405 in JSON, which shows the request reached it.
domain=${MAAS#https://maas.}
code=$(curl -s -o "$jar/post" -w '%{http_code}' -b "$jar/c" -X POST -H "Origin: https://evil.$domain" -H 'Content-Type: application/json' -d '{}' "$MAAS/maas-consumer-portal/maas/api/v1/models")
uat "cross-origin write refused" "got $code: AuthPolicy maas-portal-oidc's same-origin-writes rule missing; a cookie-session POST from another origin reached the portal" \
  bash -c "[[ $code != 2* ]] && ! grep -q '\"error\"' '$jar/post'"
for h in 'Origin: null' 'Sec-Fetch-Site: cross-site'; do
  code=$(curl -s -o "$jar/post" -w '%{http_code}' -b "$jar/c" -X POST -H "$h" -H 'Content-Type: application/json' -d '{}' "$MAAS/maas-consumer-portal/maas/api/v1/models")
  uat "write with '$h' refused" "got $code: the same-origin-writes rule let it through" \
    bash -c "[[ $code != 2* ]] && ! grep -q '\"error\"' '$jar/post'"
done
code=$(curl -s -o "$jar/post" -w '%{http_code}' -b "$jar/c" -X POST -H "Origin: $MAAS" -H 'Content-Type: application/json' -d '{}' "$MAAS/maas-consumer-portal/maas/api/v1/models")
uat "same-origin write let through" "got $code: the same-origin-writes rule refuses the portal's own Origin" \
  grep -q '"error"' "$jar/post"
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Cookie: __Host-maas_portal_proxy=forged' "$MAAS/maas-consumer-portal/")
uat "forged cookie refused" "got $code: Authorino passed a request without a valid session" test "$code" = 302
summary
