#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
h=$HOST
console=$(kc $h get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null)
uat "gitops ready"         "GitOps operator not installed: kc host get csv -n openshift-gitops-operator" \
  kc $h get argocd openshift-gitops -n openshift-gitops
uat "root ApplicationSet"  "bootstrap/00-gitops.sh not run: the root ApplicationSet apps creates one app per apps/*/application.yaml" \
  kc $h get applicationset apps -n openshift-gitops
uat "app ai-grid-policies synced" "a Helm render error in apps/ai-grid-policies (Degraded alone is an inform Policy, by design)" \
  bash -c "kc $h get applications.argoproj.io ai-grid-policies -n openshift-gitops -o jsonpath='{.status.sync.status}' | grep -qx Synced"
for a in gitops-config acm maas-db; do
  uat "app $a"            "Argo CD app not Synced/Healthy: open it in the Argo CD UI, or kc host get application $a -n openshift-gitops -o yaml" app $a
done
uat "argo cluster-admin"   "bootstrap/00-gitops.sh didn't apply bootstrap/gitops-admin.yaml" \
  bash -c "kc $h auth can-i '*' '*' --all-namespaces --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller | grep -qx yes"
uat "argo admin group"   "you're not in group cluster-admins, so Argo CD shows you nothing: rerun bootstrap/00-gitops.sh, or see docs/runbook.md Access" \
  bash -c "kc $h get group cluster-admins -o json | jq -e --arg u \"\$(kc $h whoami)\" '.users | index(\$u)' >/dev/null"
uat "praxis OCI repo"      "Argo CD app gitops-config didn't create Secret praxis-charts" kc $h get secret praxis-charts -n openshift-gitops
uat "ACM running"          "MultiClusterHub still installing (about 15 minutes), or short of CPU: kc host get mch -n open-cluster-management -o yaml" \
  bash -c "kc $h get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}' | grep -qx Running"
uat "ACM console answers"  "the acm console plugin isn't enabled: kc host get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'" \
  bash -c "kc $h get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' | grep -q '\"acm\"' && curl -s -o /dev/null -w '%{http_code}' https://$console/ | grep -qE '^(200|302)$'"
uat "local-cluster Available" "the hub's self-import didn't finish: kc host get managedcluster local-cluster -o yaml" \
  bash -c "kc $h get managedcluster local-cluster -o jsonpath='{.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}' | grep -qx True"
uat "MWRS feature gate"    "the ACM operator reset ClusterManager; rerun bootstrap/21-acm-feature-gates.sh" \
  bash -c "kc $h get clustermanager cluster-manager -o json | jq -e '.spec.workConfiguration.featureGates[] | select(.feature==\"ManifestWorkReplicaSet\" and .mode==\"Enable\")'"
uat "maas-db healthy"      "Argo CD app maas-db not synced, the CNPG operator (certified-operators) not installed, or the PVC not bound" \
  bash -c "kc $h get cluster.postgresql.cnpg.io maas-db -n maas-db -o jsonpath='{.status.phase}' | grep -qx 'Cluster in healthy state'"
uat "maas-db app secret"   "CNPG didn't bootstrap the database" kc $h get secret maas-db-app -n maas-db
uat "hub rhoai-quay-pull"  "run hack/quay-env.sh, then bootstrap/25-hub-secrets.sh" kc $h get secret rhoai-quay-pull -n ai-grid-policies
uat "one cert-manager OG"  "something added a second OperatorGroup to cert-manager-operator (Gaps 19)" \
  bash -c "[ \$(kc $h get operatorgroup -n cert-manager-operator --no-headers | wc -l) -eq 1 ]"
kchost=$(kc $h get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.keycloakHost}' 2>/dev/null)
uat "app keycloak"           "Argo CD app keycloak not Synced/Healthy" app keycloak
uat "keycloak db healthy"    "CloudNativePG Cluster keycloak-db not healthy: kc host get cluster.postgresql.cnpg.io keycloak-db -n $KEYCLOAK_NS" \
  bash -c "kc $h get cluster.postgresql.cnpg.io keycloak-db -n $KEYCLOAK_NS -o jsonpath='{.status.phase}' | grep -qx 'Cluster in healthy state'"
uat "keycloak ready"         "RHBK didn't reconcile maas-keycloak: kc host get keycloak maas-keycloak -n $KEYCLOAK_NS -o yaml" \
  bash -c "kc $h get keycloak maas-keycloak -n $KEYCLOAK_NS -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
uat "one keycloak operator"  "a second Keycloak operator was installed (MaaS's setup-keycloak.sh?)" \
  bash -c "[ \$(kc $h get csv -A --no-headers | awk '\$2 ~ /^(rhbk-operator|keycloak-operator)\./' | wc -l) -eq 1 ]"
uat "realm ai-grid discovery" "Route keycloak missing, or KeycloakRealmImport ai-grid failed: kc host get keycloakrealmimport ai-grid -n $KEYCLOAK_NS -o yaml" \
  bash -c "curl -fsS https://$kchost/realms/ai-grid/.well-known/openid-configuration | jq -e '.issuer == \"https://$kchost/realms/ai-grid\"'"
# Our Keycloak answers HTTP only through its Route, and its database only to it. Each probe first
# reaches the port from a pod the policy allows (the router; a database pod), then must time out (124)
# from a namespace with no business there, not fail to run (a wrong name or a missing pod exits 1).
# The repo server and the router have bash and /dev/tcp.
kcprobe='timeout 4 bash -c "</dev/tcp/maas-keycloak-service.'$KEYCLOAK_NS'.svc/8080"'
dbprobe='timeout 4 bash -c "</dev/tcp/keycloak-db-rw.'$KEYCLOAK_NS'.svc/5432"'
uat "hub Keycloak probe reaches 8080 from the router" "the probe itself is broken (Service maas-keycloak-service, or exec into router-default)" \
  bash -c "kc $HOST exec -n openshift-ingress deploy/router-default -- bash -c '$kcprobe'"
uat "hub Keycloak refuses other namespaces" "Keycloak maas-keycloak spec.networkPolicy.http missing or too wide (apps/keycloak), or the probe pod is missing (exit not 124)" \
  bash -c "kc $HOST exec -n openshift-gitops deploy/openshift-gitops-repo-server -- bash -c '$kcprobe' >/dev/null 2>&1; [[ \$? == 124 ]]"
uat "hub Keycloak database probe reaches 5432 from an allowed pod" "the probe itself is broken (Service keycloak-db-rw, or exec into the database pod)" \
  bash -c "kc $HOST exec -n $KEYCLOAK_NS \$(kc $HOST get pod -n $KEYCLOAK_NS -l cnpg.io/cluster=keycloak-db -o name | head -1) -c postgres -- bash -c '$dbprobe'"
uat "hub Keycloak database refuses other namespaces" "NetworkPolicy keycloak-db-ingress missing or too wide (apps/keycloak), or the probe pod is missing (exit not 124)" \
  bash -c "kc $HOST exec -n openshift-gitops deploy/openshift-gitops-repo-server -- bash -c '$dbprobe' >/dev/null 2>&1; [[ \$? == 124 ]]"
uat "hub issuer ignores forged X-Forwarded-Host" "Route maas-keycloak lacks haproxy.router.openshift.io/set-forwarded-headers: replace, and the hostname isn't pinned" \
  bash -c "kc $HOST get route maas-keycloak -n $KEYCLOAK_NS -o jsonpath='{.metadata.annotations.haproxy\\.router\\.openshift\\.io/set-forwarded-headers}' | grep -qx replace \
    && curl -fsS -H 'X-Forwarded-Host: forged.invalid' https://$kchost/realms/ai-grid/.well-known/openid-configuration | jq -e '.issuer == \"https://$kchost/realms/ai-grid\"'"
uat "hub tenant issuer"      "bootstrap/35-keycloak.sh didn't write ConfigMap ai-grid-hub-info" \
  bash -c "kc $h get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.tenantIssuer}' | grep -q '/realms/ai-grid$'"
claims() { local pw; pw=$(kc $h get secret ai-grid-test-users -n $KEYCLOAK_NS -o jsonpath="{.data.$1}" | base64 -d)
  printf %s "$pw" | curl -fsS -d grant_type=password -d client_id=maas-cli -d scope=openid --data-urlencode "username=$1" \
    --data-urlencode password@- https://$kchost/realms/ai-grid/protocol/openid-connect/token | jq -r .access_token | cut -d. -f2 | tr '_-' '/+' \
    | { read -r t; while (( ${#t} % 4 )); do t="$t="; done; printf '%s' "$t"; } | base64 -d 2>/dev/null; }
# one <filter> [jq options]: true only when exactly one JSON value comes in and <filter> holds for it.
# Plain `jq -e` passes on empty input on jq 1.6, so a failed sign-in would PASS there.
one() { local f=$1; shift; jq -se "$@" "length == 1 and (.[0] | $f)"; }
export -f claims one; export h kchost   # bash -c subshells see only exported names
uat "alice token: org1"      "the maas orgs mapper emits another shape (Step 2's note), or alice isn't an org1 member" \
  bash -c "claims alice | one '.\"https://redhat.com/maas/orgs\" | length == 1 and .[0].organization_name == \"org1\" and (.[0].organization_id | test(\"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$\"))'"
uat "alice token: groups"    "scope maas's groups mapper doesn't emit maas_groups from the user's groups, or alice isn't in group1 under <org1 id>" \
  bash -c "claims alice | one '. as \$t | .groups == [\$t[\"https://redhat.com/maas/orgs\"][0].organization_id + \"/group1\"]'"
# The portal's sign-in proxy can't hand a refreshed session back to the browser (Authorino asks it
# on the browser's behalf), so a token must last the whole portal session: 1 hour.
uat "alice token lasts the portal session" "client maas-cli's access.token.lifespan isn't 3600: rerun bootstrap/36-portal-clients.sh" \
  bash -c "claims alice | one '.exp - .iat == 3600'"
uat "dave token: no groups"  "dave was given a group; he must stay in no subscription" \
  bash -c "claims dave | one '(.groups // []) | length == 0'"
# The broker (ODH-ADR-MS-0007). The security fixes live only in realm config, and a realm imported
# before the broker keeps its old shape, so read the config back through the admin API. Only the
# results leave this shell; the admin token never reaches a subshell or argv.
kt=$(kc $h get secret maas-keycloak-initial-admin -n $KEYCLOAK_NS -o json \
  | jq -r '.data | (.username | @base64d), (.password | @base64d)' | { read -r u; read -r p
    printf %s "$p" | curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$u" \
      --data-urlencode password@- "https://$kchost/realms/master/protocol/openid-connect/token"; } | jq -r .access_token)
kget() { curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$kt") "https://$kchost/admin/realms/$1"; }
kc_idps=$(kget ai-grid/identity-provider/instances)
kc_flow=$(kget "ai-grid/authentication/flows/ai-grid%20first%20broker%20login/executions")
kc_names=$(for i in org1-idp org2-idp; do kget ai-grid/identity-provider/instances/$i/mappers; done \
  | jq -sc '[.[][] | select(.identityProviderMapper == "oidc-username-idp-mapper") | .config.template]')
kc_org1=$(kget "ai-grid/organizations?search=org1&exact=true" | jq -r '.[0].id // ""')
kc_email=$(for r in org1-idp org2-idp ai-grid; do kget $r/users/profile; done \
  | jq -sc '[.[] | .attributes[] | select(.name == "email") | .permissions.edit]')
kc_gm=$(kget "ai-grid/client-scopes/$(kget ai-grid/client-scopes | jq -r '.[] | select(.name == "maas") | .id')/protocol-mappers/models" \
  | jq -c '[.[] | select(.name == "groups") | {protocolMapper, a: .config["user.attribute"], m: .config.multivalued, g: .config["aggregate.attrs"]}]')
kc_groups=$(kget "ai-grid/groups?max=1000" | jq -c '[.[].name]')
unset kt
gov_org1=$(yq 'select(.kind == "MaaSSubscription") | .spec.owner.groups[0].name' spokes/tenant/governance.yaml | cut -d/ -f1)
export kc_idps kc_flow kc_names kc_org1 kc_email kc_gm kc_groups gov_org1
uat "broker: realm ai-grid is the broker's" "realm ai-grid predates the broker (the operator never re-imports): docs/runbook.md, Upgrading realm ai-grid to the broker" \
  bash -c '[[ -n $kc_org1 && $kc_org1 == "$gov_org1" ]]'
uat "broker: providers use the first-login flow" "an identity provider is missing or uses Keycloak's default first broker login (profile form, account linking)" \
  bash -c 'jq -e "map(select(.alias == \"org1-idp\" or .alias == \"org2-idp\") | .firstBrokerLoginFlowAlias) == [\"ai-grid first broker login\", \"ai-grid first broker login\"]" <<<"$kc_idps"'
uat "broker: first login only creates and onboards" "flow ai-grid first broker login gained a step (a review form or account linking would undo F1/F2)" \
  bash -c 'jq -e "map({providerId, requirement}) == [{providerId: \"idp-create-user-if-unique\", requirement: \"REQUIRED\"}, {providerId: \"idp-add-organization-member\", requirement: \"REQUIRED\"}]" <<<"$kc_flow"'
uat "broker: usernames from the provider's subject" "a username mapper's template isn't \${ALIAS}.\${CLAIM.sub} (the import's placeholder handling, or an edit)" \
  bash -c 'jq -e ". == [\"\${ALIAS}.\${CLAIM.sub}\", \"\${ALIAS}.\${CLAIM.sub}\"]" <<<"$kc_names"'
uat "broker: groups claim from maas_groups" "scope maas's groups mapper isn't the multivalued, aggregating maas_groups attribute mapper: rerun bootstrap/35-keycloak.sh" \
  bash -c 'jq -e ". == [{protocolMapper: \"oidc-usermodel-attribute-mapper\", a: \"maas_groups\", m: \"true\", g: \"true\"}]" <<<"$kc_gm"'
uat "broker: no <org id>:<group> groups left" "a group from the earlier shape is left: rerun bootstrap/35-keycloak.sh" \
  bash -c 'jq -e "map(select(contains(\":\"))) | length == 0" <<<"$kc_groups"'
uat "realms: email is admin-only" "bootstrap/35-keycloak.sh didn't set the user profile of org1-idp, org2-idp or ai-grid" \
  bash -c 'jq -e ". == [[\"admin\"], [\"admin\"], [\"admin\"]]" <<<"$kc_email"'
for r in org1-idp org2-idp; do
  uat "tenant realm $r answers" "KeycloakRealmImport $r not Done: Secret ai-grid-tenant-idps missing when it ran?" \
    curl -fsS -o /dev/null "https://$kchost/realms/$r/.well-known/openid-configuration"
done
# A brokered browser sign-in, as the portal does it (maas-cli with PKCE, stopping at the portal callback):
# org1-idp's alice comes back as org1-idp.<subject>, with org1's claim and group. With an email address,
# it starts at the broker's username page and must be sent on to <idp> by the address's domain; without
# one, kc_idp_hint picks <idp> directly.
broker_claims() { local idp=$1 u=$2 email=${3:-} j loc code ver chal action hint=()
  j=$(mktemp); ver=$(openssl rand -hex 32); chal=$(printf %s "$ver" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
  # follow <curl args>: follows up to 10 redirects by hand, stops at the portal callback and prints it (or
  # nothing when a page is served, left in $j.page).
  follow() { local loc url n=0; loc=$(curl -sS --connect-timeout 5 --max-time 20 -c $j -b $j -o $j.page -w '%{redirect_url}' "$@")
    while [[ -n $loc && $loc != "$cb"* ]] && (( n++ < 10 )); do url=$loc
      loc=$(curl -sS --connect-timeout 5 --max-time 20 -c $j -b $j -o $j.page -w '%{redirect_url}' "$url"); done
    [[ $loc == "$cb"* ]] && printf %s "$loc"; }
  form() { tr '\n' ' ' <$j.page | grep -o 'id="kc-form-login"[^>]*' | grep -o 'action="[^"]*"' | sed 's/action="//; s/"$//; s/&amp;/\&/g'; }
  [[ -n $email ]] || hint=(--data-urlencode "kc_idp_hint=$idp")
  follow -G "https://$kchost/realms/ai-grid/protocol/openid-connect/auth" --data-urlencode client_id=maas-cli --data-urlencode response_type=code \
    --data-urlencode scope=openid --data-urlencode "redirect_uri=$cb" --data-urlencode code_challenge=$chal \
    --data-urlencode code_challenge_method=S256 "${hint[@]}" >/dev/null
  [[ -z $email ]] || printf 'username=%s' "$(jq -nr --arg e "$email" '$e | @uri')" | follow --data-binary @- "$(form)" >/dev/null
  action=$(form)
  # The login form must be the organization's provider's, not the broker's own.
  [[ $action == "https://$kchost/realms/$idp/"* ]] || { rm -f $j $j.page; return 1; }
  loc=$(printf 'username=%s&password=%s' "$u" "$(kc $h get secret ai-grid-test-users -n $KEYCLOAK_NS -o jsonpath="{.data.$idp-$u}" | base64 -d | jq -sRr @uri)" \
    | follow --data-binary @- "$action")
  code=$(grep -o '[?&]code=[^&]*' <<<"$loc" | head -1 | cut -d= -f2); rm -f $j $j.page
  [[ -n $code ]] && curl -fsS --connect-timeout 5 --max-time 20 -d grant_type=authorization_code -d client_id=maas-cli --data-urlencode "code=$code" --data-urlencode "redirect_uri=$cb" \
    -d code_verifier=$ver "https://$kchost/realms/ai-grid/protocol/openid-connect/token" | jq -r .access_token | cut -d. -f2 | tr '_-' '/+' \
    | { read -r t; while (( ${#t} % 4 )); do t="$t="; done; printf '%s' "$t"; } | base64 -d 2>/dev/null; }
# The first portal spoke whose apps domain the hub knows (no spoke kubeconfig needed); none, no sign-in check.
ps=$(portal_spokes)
for s in $ps; do d=$(apps_domain "$s"); [[ -n $d ]] && { cb="https://maas.$d/oauth2/callback"; break; }; done
export -f broker_claims; export cb
brokered="(.preferred_username | startswith(\"org1-idp.\")) and .groups == [\$o + \"/group1\"] and .\"https://redhat.com/maas/orgs\"[0].organization_id == \$o"
[[ -n ${cb:-} ]] && uat "brokered sign-in: org1-idp alice" "the org1-idp login form, the broker's mappers, or maas-cli's callback for the first ingress spoke" \
  bash -c "broker_claims org1-idp alice | one '$brokered' --arg o $gov_org1"
[[ -n ${cb:-} ]] && uat "brokered sign-in by email domain: org1" "alice@org1.example.com didn't reach org1-idp: organization org1's domain, or org1-idp's kc.org.domain and redirect-on-email-match config" \
  bash -c "broker_claims org1-idp alice alice@org1.example.com | one '$brokered' --arg o $gov_org1"
# Keycloak answers 400 both for an unknown client and for a bad redirect URI; only the page text differs.
client_gone() { curl -s "https://$kchost/realms/ai-grid/protocol/openid-connect/auth?client_id=$1&response_type=code&scope=openid&redirect_uri=https%3A%2F%2Fx" | grep -q 'Client not found'; }
export -f client_gone; export kchost
uat "no maas-portal client"   "the confidential client from an earlier portal design is left: rerun bootstrap/36-portal-clients.sh" \
  client_gone maas-portal
# maas-cli is a public client, so it must take exactly the portal callbacks of portal_spokes (lib.sh),
# as 36-portal-clients.sh writes them: a departed spoke's leftover one could receive a tenant's sign-in
# code once its domain is reused. Reading the client needs Keycloak's admin login, as that script does.
want=$(for s in $ps; do echo "https://maas.$(apps_domain "$s")/oauth2/callback"; done | jq -Rsc 'split("\n") | map(select(. != "")) | sort')
redirect_uris() { local au ap tok
  au=$(kc $h get secret maas-keycloak-initial-admin -n $KEYCLOAK_NS -o jsonpath='{.data.username}' | base64 -d)
  ap=$(kc $h get secret maas-keycloak-initial-admin -n $KEYCLOAK_NS -o jsonpath='{.data.password}' | base64 -d)
  tok=$(printf %s "$ap" | curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$au" \
    --data-urlencode password@- "https://$kchost/realms/master/protocol/openid-connect/token" | jq -r .access_token)
  curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$tok") "https://$kchost/admin/realms/ai-grid/clients?clientId=maas-cli" \
    | jq -c '.[0].redirectUris | sort'; }
export -f redirect_uris; export want
uat "maas-cli takes exactly the portal callbacks" "maas-cli's redirect URIs aren't the invited spokes' and local-cluster's callbacks: rerun bootstrap/36-portal-clients.sh after adding or removing a spoke, with SPOKES leaving out local-cluster once the hub has left the grid (or a spoke's ManagedCluster lacks its console URL claim)" \
  bash -c '[[ $(redirect_uris) == "$want" ]]'
for s in $ps; do
  d=$(apps_domain "$s")
  uat "portal redirect $s"   "client maas-cli rejects $s's portal callback: rerun bootstrap/36-portal-clients.sh after adding a spoke or a domain change" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' \"https://$kchost/realms/ai-grid/protocol/openid-connect/auth?client_id=maas-cli&response_type=code&scope=openid&code_challenge_method=S256&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&redirect_uri=https%3A%2F%2Fmaas.$d%2Foauth2%2Fcallback\" | grep -qx 200"
  uat "no login client ocp-$s" "a cluster-login client from the old portal design is left: rerun bootstrap/36-portal-clients.sh" \
    client_gone ocp-$s
done
summary
