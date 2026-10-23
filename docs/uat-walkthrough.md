# Pair UAT walkthrough

This walkthrough is for the person learning the environment, working through it with an agent as
a pair. It covers checkpoints 2 to 8 in build order, in one sitting. Checkpoint 1, the hub platform
(Task 2), already passed and is recorded in the runbook's UAT log.

Each checkpoint has **Open** (what to look at), **What it is** (the concept), **Expect** (healthy
versus broken), **Try** (one action you run yourself), and **Questions**, with short answers in a
collapsed block. The following times are estimates; the whole sitting takes about two and a half
hours.

| Checkpoint | Task | Estimate |
|---|---|---|
| 2. Keycloak | Task 3 | 20 minutes |
| 3. Grid enrollment | Task 4 | 15 minutes |
| 4. Spoke delivery | Task 5 | 25 minutes |
| 5. Models and tenant intent | Task 6 | 20 minutes |
| 6. Tenant end to end | Task 7, Steps 1-3 | 25 minutes |
| 7. Portal sign-in | Task 7, Steps 5-6 | 15 minutes |
| 8. Rebuild and teardown | Task 8 | 25 minutes |
| Record the result | | 5 minutes |

## Before you start

Make sure you have the following:

- A browser signed in to the hub's OpenShift console as a cluster admin.
- A terminal in the root of this repository, with `HOST_KUBECONFIG` set to the hub's kubeconfig file.
- `oc`, `jq`, `curl`, and `openssl` on your path.

Point `oc` at the hub for the whole sitting:

```bash
export KUBECONFIG="$HOST_KUBECONFIG"
```

On this one-cluster build the hub is also the only spoke, `local-cluster`, so one kubeconfig
reaches both. The plan writes commands as `kc host ...` (the hub) and `kc local-cluster ...` (the
spoke). Both are `oc` against this one cluster. When a second spoke exists, the spoke commands need
that spoke's kubeconfig instead.

Run the automated checks first. Don't start the walkthrough until they pass:

```bash
make verify
```

Every script ends with `ALL PASS`. If one fails, its `likely:` line names where to look; fix that
first.

Set two variables that later checkpoints use. Neither one holds a secret:

```bash
KC=$(oc get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.keycloakHost}')
MAAS=https://$(oc get route maas-gateway-route -n openshift-ingress -o jsonpath='{.spec.host}')
echo "$KC" "$MAAS"
```

`MAAS` has the form `https://maas.APPS_DOMAIN`, where `APPS_DOMAIN` is the cluster's apps domain.

To open the Argo CD UI, get its host name and open it in the browser. Sign in with OpenShift:

```bash
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'
```

## Checkpoint 2: Keycloak (Task 3)

**Open:**

- In Argo CD, the `keycloak` app: the database `Cluster` `keycloak-db`, the `Keycloak`
  `maas-keycloak`, the Route `maas-keycloak`, and the `KeycloakRealmImport` `ai-grid`.
- The admin console at `https://$KC/admin/`. Read the admin user name and password in your own
  terminal, not through the agent:

  ```bash
  oc extract secret/maas-keycloak-initial-admin -n keycloak --to=-
  ```

- In realm `ai-grid`:
  - **Organizations:** `org1` and `org2`, and their members.
  - **Groups:** one group per organization, named with its ID, each holding `group1`. On `group1`'s
    **Attributes** tab, `maas_groups` is `<org1 id>/group1`: the token form MaaS reads (ODH-ADR-MS-0007).
  - **Users:** `alice`, `dave`, and `bob`. On `alice`'s **Attributes** tab, find `maas_orgs`.
  - **Client scopes > maas > Mappers:** `username`, `groups` (the user's groups' `maas_groups` values), and
    the organization mapper.
  - **Clients > maas-cli:** a public client. Its **Valid redirect URIs** list
    `https://maas.APPS_DOMAIN/oauth2/callback` for each ingress spoke.
- The discovery document at `https://$KC/realms/ai-grid/.well-known/openid-configuration`.

**What it is:** Keycloak is the provider's sign-in service for every organization. A user signs in
once and gets a token that says who they are, which organization they belong to (the
`https://redhat.com/maas/orgs` claim), and which groups they're in. MaaS on every ingress spoke
trusts this one realm, and subscriptions match the groups. Clusters don't belong to organizations,
so the realm lives on the hub.

**Expect:** the discovery document's `issuer` equals `tenantIssuer` in ConfigMap
`ai-grid-hub-info`. `alice` is a member of `org1` and in group `group1` under `<org1 id>`. `dave` is in `org1`
with no group. The demo order's own Keycloak, the one behind the cluster's SSO login, is unchanged.
Broken looks like an issuer with `http://` or a different host, which breaks every MaaS token check
later.

**Try:** compare the two issuers yourself:

```bash
curl -s "https://$KC/realms/ai-grid/.well-known/openid-configuration" | jq -r .issuer
oc get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.tenantIssuer}'; echo
```

The two lines must match character for character.

**Brokered sign-in.** Each organization signs in through its own identity provider: realms `org1-idp`
and `org2-idp` stand in for a customer's own, and realm `ai-grid` brokers them. Open:

- In realm `ai-grid`, **Identity providers:** `org1-idp` and `org2-idp`, each linked to its
  organization (**Organizations > org1 > Identity providers**), with **First login flow** set to
  `ai-grid first broker login` (**Authentication**: only *Create User If Unique* and *Organization
  Member Onboard*, both Required).
- Secret `ai-grid-tenant-idps` in namespace `keycloak`: Keycloak's public URL and the two broker client
  secrets (don't print it).

Then sign in to a portal (`https://maas.APPS_DOMAIN/`) as `alice@org1.example.com`. Keycloak sees the
domain and sends you to `org1-idp`'s login page. Sign in as `alice` with the password from:

```bash
oc extract secret/ai-grid-test-users -n keycloak --keys=org1-idp-alice --to=-
```

**Expect:** the portal lists org1's models. In realm `ai-grid`, a new user `org1-idp.<id>` (the
provider's alias and its fixed subject) is a **Managed** member of `org1` and in group
`<org1 id>/group1`. `dave@org1.example.com` (key `org1-idp-dave`) signs in but sees no models, and
`bob@org2.example.com` goes to `org2-idp`. Plain `alice`, `dave` and `bob` are realm `ai-grid`'s own
users, for the CLI's password grant; their email addresses are outside the organizations' domains on
purpose, so a brokered user never matches one.

**Questions:**

1. Which claim tells MaaS a user's organization, and which claim do subscriptions match?
2. Why one realm for all organizations rather than one realm per organization?
3. Why is `dave` in an organization but in no group?

<details>
<summary>Answers</summary>

1. `https://redhat.com/maas/orgs` carries the organization. Subscriptions match `groups`.
2. MaaS trusts one issuer per tenant configuration (`AITenant`), and Keycloak Organizations keep the
   organizations apart inside one realm. One realm also gives the console one place to list them.
3. He's the negative test: a valid user in an organization who has no subscription, so he gets no
   model (checkpoint 6).

</details>

## Checkpoint 3: Grid enrollment (Task 4)

**Open:**

- In Argo CD, the `grid-enrollment` app: the chart's objects and the CA bootstrap hook Job.
- The enrollment namespace and the hub site's Secrets:

  ```bash
  oc get all,secret -n grid-enrollment
  oc get secret -n grid
  ```

**What it is:** enrollment is the grid's front door and certificate authority (CA). A new site shows
a one-time invite token, gets a signed identity, and from then on proves who it is with that
identity when it talks to other sites. The hub's own site skipped the door (`hubSite`): the CA signed
its identity directly, which is why `grid-site-identity` already exists in namespace `grid`. Later
sites get their token through ACM and reach enrollment through a Route that Task 11 adds.

**Expect:** one enrollment pod and one database pod Running, no Route, and in `grid` the Secrets
`grid-site-identity`, `grid-ca`, and `grid-swim-key`. A missing identity means the bootstrap Job
failed; read its log.

**Try:** check who signed enrollment's serving certificate:

```bash
oc get secret enrollment-serving-tls -n grid-enrollment -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -issuer -enddate
```

The issuer names `grid-ca`, the grid's own CA, not the cluster's.

**Questions:**

1. Why does enrollment live on the ACM hub here?
2. What does a remote spoke need from enrollment that `local-cluster` didn't?
3. What breaks if the enrollment database's volume is deleted?

<details>
<summary>Answers</summary>

1. The grid's invite policy is an ACM Policy, so enrollment runs where ACM can place it (decision D2).
2. An invite token delivered by ACM and a Route to reach enrollment from outside the cluster.
3. Enrollment forgets which sites joined. The volume is kept on uninstall
   (`helm.sh/resource-policy: keep`) to make that harder.

</details>

## Checkpoint 4: Spoke delivery (Task 5)

The labelling already happened during the build. This checkpoint walks the result.

**Open:**

- In the console, the **Fleet management** perspective > **Clusters** > `local-cluster`: its labels
  `ai-grid/enabled=true`, `ai-grid/role=combined`, and `location=us-east`.
- **Governance > Policies:** the Policies and their per-cluster status. They are `ai-grid-ready`,
  `authorino-service-ca`, `grid-upstream-key`, `maas-db`, `maas-gateway-ca`, `maas-route`,
  `rhoai-nightly-prereqs`, `rhoai-pull-secret`, `tenant-oidc`, and `tenant-portal`.
- In Argo CD, the per-spoke Applications: `platform-local-cluster` and
  `grid-operator-local-cluster`.
- The placement decisions and the OpenShift AI install:

  ```bash
  oc get placementdecisions -n openshift-gitops
  oc get datasciencecluster default-dsc
  ```

**What it is:** this is the hub's write path again, with ACM doing the delivery. The label is the
only thing a provider sets. Placements turn labels into a list of clusters. Policies make small,
exact changes on those clusters and report whether each cluster complies, which is the read path:
status flowing back to the hub. ApplicationSets give each selected cluster its own Argo CD
Application, which installs the large pieces, such as OpenShift AI and the grid, from git.
`ai-grid-ready` only reports.

**Expect:** `local-cluster` in the placement decisions; every Policy Compliant; the platform
Application Synced; the DSC Ready. Broken looks like a Policy stuck NonCompliant (open its status
message), an Application with a sync error rather than a retry, or no decision for a labelled
cluster (check the cluster set binding).

**Try:** read the Policy that the console uses as its "provisioned" signal, on the cluster's copy:

```bash
oc get policy ai-grid-policies.ai-grid-ready -n local-cluster \
  -o jsonpath='{.status.compliant}{"\n"}{.status.details[0].history[0].message}{"\n"}'
```

ACM copies each Policy into the managed cluster's namespace as `<policy namespace>.<name>`, so
`maas-db` appears as `maas-db.maas-db`. `Compliant` here means the DSC is Ready and the grid operator
is running (decision D3).

**Questions:**

1. What decides which values a spoke gets?
2. Why can't the pull secret be a separate Secret on this cluster?
3. If you removed `ai-grid/enabled` from `local-cluster`, what stops, and what stays installed?

<details>
<summary>Answers</summary>

1. Its labels: `ai-grid/role` picks the ingress or inference pieces, and the per-spoke directory
   `spokes/clusters/<name>` holds what is specific to it.
2. The cluster pulls images with the one global pull secret, `openshift-config/pull-secret`. A
   standard control plane has no add-on that merges a second Secret, so Policy `rhoai-pull-secret`
   merges the `quay.io/rhoai` entry into it.
3. Delivery stops: the six per-spoke Applications go away. Everything already installed stays,
   because nothing prunes it (checkpoint 8 shows this).

</details>

## Checkpoint 5: Models and tenant intent (Task 6)

**Open:**

- The OpenShift AI dashboard (`oc get route -n redhat-ods-applications`), **Models**:
  `facebook-opt-125m` serving in project `aigrid-models`.
- In Argo CD: `models-local-cluster`, `tenant-local-cluster`, `grid-provider-local-cluster`, and
  `grid-consumer-local-cluster`.
- The MaaS objects and the grid's records:

  ```bash
  oc get externalprovider,externalmodel,maasmodelref,maassubscription,maasauthpolicy -n models-as-a-service
  oc get gridsites,inferenceproviders
  ```

**What it is:** the model runs once, on a serving spoke. MaaS never calls it directly: it calls the
grid's consumer gateway (the `ExternalProvider`), and the grid picks a site whose provider gateway
forwards to the model. The subscription and auth policy `opt-125m-org1` say who can call the model
and how much: Keycloak group `group1` of `org1` (token form `<org1 id>/group1`) at 100 tokens a minute. Models are per spoke in git;
tenant intent is one copy delivered to every ingress spoke. The model and subscription are a test
fixture that the provider console replaces.

**Expect:** the model Ready, `MaaSModelRef` `facebook-opt-125m` Ready, exactly one
`InferenceProvider`, and `GridSite` `local-cluster` present. The site stays `Discovered` until a peer
site joins. Two `InferenceProvider`s mean odh-model-controller started publishing one too. Broken
looks like a `MaaSModelRef` stuck Pending: no subscription and auth policy pair, or the gateway is
unreachable.

**Try:** follow the model's address from MaaS to the grid:

```bash
oc get externalprovider grid-provider -n models-as-a-service -o jsonpath='{.spec.endpoint}{"\n"}'
oc get svc -n grid
```

The `ExternalProvider` (named `grid-provider`, although it points at the consumer side) targets
`grid-gateway.grid.svc.cluster.local`, the consumer gateway, not the model's own Service in
`aigrid-models`.

**Questions:**

1. Why does MaaS reach the model through the grid instead of directly?
2. What do you change in git to serve this model on a second spoke?
3. Where does a subscription the console writes end up?

<details>
<summary>Answers</summary>

1. So the grid can choose among sites, balancing load and avoiding failed sites. MaaS sees one
   endpoint no matter how many sites serve the model.
2. Add the model to that spoke's directory, `spokes/clusters/<spoke>/models/kustomization.yaml`,
   and give the spoke a role that serves models (`inference` or `combined`).
3. As a `MaaSSubscription` and a matching `MaaSAuthPolicy` in `models-as-a-service` on every
   ingress spoke.

</details>

## Checkpoint 6: Tenant end to end (Task 7, Steps 1-3)

You run the calls a tenant makes, by hand.

**Open:** a terminal with `KC` and `MAAS` set, and a second terminal for logs.

1. Get `alice`'s access token. The password flows from the Secret straight into `curl` through a
   pipe, so it never lands in a variable or on screen:

   ```bash
   auth() { printf 'Authorization: Bearer %s\n' "$1"; }
   TOKEN=$(oc get secret ai-grid-test-users -n keycloak -o jsonpath='{.data.alice}' | base64 -d \
     | curl -s -d grant_type=password -d client_id=maas-cli -d scope=openid -d username=alice \
         --data-urlencode password@- "https://$KC/realms/ai-grid/protocol/openid-connect/token" \
     | jq -r .access_token)
   ```

2. Read the token's claims locally:

   ```bash
   cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+' \
     | jq -R '@base64d | fromjson | {iss, preferred_username, groups, orgs: .["https://redhat.com/maas/orgs"]}'
   ```

3. List the models MaaS offers `alice`, then mint an API key:

   ```bash
   curl -s -H @<(auth "$TOKEN") "$MAAS/maas-api/v1/models" | jq '.data[] | {id, url}'
   KEY=$(curl -s -X POST -H @<(auth "$TOKEN") -H 'Content-Type: application/json' \
     -d '{"name":"uat","expiresIn":"1d"}' "$MAAS/maas-api/v1/api-keys" | jq -r .key)
   ```

4. Call the model with the key:

   ```bash
   curl -s -H @<(auth "$KEY") -H 'Content-Type: application/json' \
     -d '{"model":"facebook-opt-125m","messages":[{"role":"user","content":"Hello"}],"max_tokens":20}' \
     "$MAAS/models-as-a-service/facebook-opt-125m/v1/chat/completions" | jq .
   ```

5. In the second terminal, watch each hop as you repeat step 4:

   ```bash
   oc logs deploy/grid-gateway -n grid --tail=5     # consumer gateway
   oc logs deploy/grid-provider -n grid --tail=5    # provider gateway
   oc get pods -n aigrid-models                     # then oc logs POD_NAME -n aigrid-models
   ```

**What it is:** this is everything the provider set up, seen from the tenant's side. Keycloak proves
who the user is; MaaS checks the token, the subscription, and the rate limit; the grid picks a site;
the site's gateway forwards to vLLM. With one site the grid's choice is trivial. The same path picks
between sites once there are two (Tasks 11 and 12).

**Expect:** the token's `iss` equals the discovery document's issuer, `groups` is `["<org1 id>/group1"]`,
and the organization claim has one `org1` entry. The model list shows `facebook-opt-125m` with a URL
under `$MAAS`. The call returns `200` with a few words of text; opt-125m is a tiny model, so the text
is rarely sensible. Each hop logs one line. Broken looks like a `401` (issuer mismatch) or an empty
model list (group mismatch).

**Try:** hit the rate limit. Repeat step 4 with `"max_tokens":50` until the reply is `429 Too Many
Requests`. Because the subscription allows 100 tokens a minute, prompt and completion tokens
together run out after about two calls. Wait a minute and the calls succeed again.

Then try `dave` (repeat step 1 with `dave` in both places). His token is valid, but the model list
fails. This MaaS build answers `500` with `AUTH_FAILURE` for a user with no groups, not `403`; that's
a known upstream bug, not an environment fault.

When you're done, clear the variables: `unset TOKEN KEY`.

**Questions:**

1. Which component rejected `dave`, and why?
2. Where in this path does a second site change anything?
3. What do you change to give `dave` access?

<details>
<summary>Answers</summary>

1. MaaS. His token is valid, but no subscription names any of his groups, because he has none.
2. At the consumer gateway, which chooses between sites' provider gateways.
3. Add him to `group1` under `<org1 id>` in Keycloak, or add a subscription and auth policy for a group he's in.

</details>

## Checkpoint 7: Portal sign-in (Task 7, Steps 5-6)

You sign in to the MaaS Portal, the tenant UI, yourself.

**Open:**

1. Read `alice`'s password in your own terminal:

   ```bash
   oc extract secret/ai-grid-test-users -n keycloak --keys=alice --to=-
   ```

2. In a private browser window, open `https://maas.APPS_DOMAIN/maas-consumer-portal/` (the value of
   `$MAAS` followed by `/maas-consumer-portal/`).
3. Sign in as `alice`: Keycloak asks for the user name, then the password.

**What it is:** the portal is the tenant's front door, separate from the cluster's own login. A small
sign-in proxy (namespace `aigrid-portal-auth`) holds the browser session against the hub's Keycloak.
The MaaS gateway asks the proxy about every portal request and hands the portal the user's Keycloak
token, which MaaS trusts. The tenant never becomes an OpenShift user.

**Expect:** check each of the following in the browser:

- The sign-in page is Keycloak's, for realm `ai-grid`; the address bar shows the Keycloak host and
  `/realms/ai-grid/`.
- After sign-in, the portal opens at `/maas-consumer-portal/`.
- The model list shows `facebook-opt-125m`.
- The user menu or a namespace picker might show errors. That's a known gap: the portal's
  Kubernetes-backed calls check the token against the cluster API, which doesn't accept Keycloak
  tokens.
- The session lasts 1 hour. After that, the portal sends you back to Keycloak to sign in again.

**Try:** in the same browser window, open the OpenShift console for the cluster and sign in as you
normally do. The console works. This checks the certificate fix: the MaaS gateway's certificate
names only `maas.APPS_DOMAIN`, so the browser doesn't reuse the gateway's HTTP/2 connection for the
console or Keycloak, which the gateway answers with `404`.

Optional: sign out at `https://maas.APPS_DOMAIN/oauth2/sign_out`, then sign in as `dave`. The portal
opens but lists no models.

**Questions:**

1. Why doesn't the tenant become an OpenShift user?
2. Why must the portal use the same Keycloak client as the CLI?
3. What stops another page under the apps domain from using your portal session?

<details>
<summary>Answers</summary>

1. Tenant and cluster logins stay separate (decision D6): the proxy signs in against the hub
   Keycloak directly, and the cluster's OAuth still lists only `rhbk`.
2. MaaS matches the token's `azp` (the client that requested it) against the one `clientId` in its
   `AITenant`. A token from a second client is refused with `403`.
3. The session cookie is host-only (a `__Host-` cookie for `maas.APPS_DOMAIN`), and the AuthPolicy
   rule `same-origin-writes` refuses cookie-session writes whose `Origin` isn't the portal's.

</details>

## Checkpoint 8: Rebuild and teardown (Task 8)

**Open:**

- `docs/runbook.md`, section "Build, rebuild, and tear down".
- The `Makefile`: targets `hub`, `spokes`, `all`, `verify`, and `teardown`.
- `apps/ai-grid-spokes/manifests/templates/_generators.tpl`: the generator that takes spoke
  membership from ACM placement `ai-grid-spokes`.

**What it is:** the whole environment rebuilds from this repository with `make hub`, one commit,
and `make spokes`, then **Add to AI Grid** in the console. Taking a cluster out of the grid stops delivery without uninstalling anything.

### Repeat the unlabel drill

The agent ran this drill during the build. Repeat it and watch Argo CD:

1. In Argo CD, filter the Applications to `local-cluster`.
2. Remove the label:

   ```bash
   oc label managedcluster local-cluster ai-grid/enabled-
   ```

3. Watch the six Applications disappear, within about a minute: `platform-`, `grid-operator-`,
   `grid-provider-`, `grid-consumer-`, `models-`, and `tenant-local-cluster`. In a terminal:

   ```bash
   oc get applications.argoproj.io -n openshift-gitops -w
   ```

4. Confirm that nothing was uninstalled:

   ```bash
   oc get datasciencecluster default-dsc
   oc get deploy -n grid
   oc get pods -n aigrid-models
   ```

5. Restore the label, and watch the Applications come back:

   ```bash
   bash bootstrap/40-spoke.sh
   ```

6. Run `make verify` again. Every script ends with `ALL PASS`.

**Expect:** the six Applications go and come back; the DSC stays Ready throughout; the grid
gateways, the model, and maas-api keep running. If anything is deleted, stop: an ApplicationSet
lacks `preserveResourcesOnDeletion`.

### Teardown: read, don't run

`make teardown` runs `bootstrap/99-teardown.sh`, which stops delivery and leaves what it installed:

1. It unlabels each spoke.
2. It deletes the root ApplicationSet `apps`, so Argo CD can't recreate the delivery Applications.
3. It deletes the ApplicationSets, Policies, Placements, and bindings that the apps `ai-grid-spokes`
   and `ai-grid-policies` created, found by Argo CD's tracking annotation, then those two apps.
4. It deletes the `ManagedCluster` of each remote spoke.

It's safe in principle because no Application has a resources finalizer (except a remote spoke's
`submariner-<site>`, which takes that spoke off the cross-cluster network), every ApplicationSet
preserves resources on deletion, and ACM Policies don't remove what they created. So OpenShift AI,
the grid, and the hub services keep running, no longer managed. Teardown hasn't run on this cluster,
so that reasoning is untested here. Afterwards, `make all` and Add to AI Grid in the console bring delivery back. Whether to run it is
your call; don't run it during this walkthrough.

### The rebuild drill

The rebuild drill needs a fresh demo.redhat.com order and PR 1 merged into
`ai-grid-cloud/ai-grid-env-setup` `main`. On the fresh order you run `make hub`, commit the new
`hubSiteDigest` that `bootstrap/50-grid-hub-info.sh` prints, then run `make spokes`, add `local-cluster` from the console, and run `make verify`. It isn't
part of this sitting.

**Questions:**

1. Why does a label removal stop delivery but leave OpenShift AI installed?
2. Why does a new hub need a commit between `make hub` and `make spokes`?
3. What does `make teardown` leave behind on `local-cluster`?

<details>
<summary>Answers</summary>

1. The label decides placement, and placement decides which Applications exist. Deleting an
   Application preserves its resources, so what it installed stays.
2. A new hub has a new grid CA. The provider gateways pin the hub site's certificate digest
   (`hubSiteDigest` in `apps/ai-grid-spokes/manifests/values.yaml`), and Argo CD reads that value
   from git, so it must be committed before the spokes install.
3. Everything that was installed: OpenShift AI, MaaS, the grid, the model, and the hub services,
   such as ACM, Keycloak, enrollment, and the databases. Only delivery and its Policies go.

</details>

## Record the result

In `docs/runbook.md`, section "UAT log", update rows 2 to 7, and add a row 8 for Task 8:

| Date | Checkpoint | `make verify` | Pair UAT result | Notes |
|---|---|---|---|---|
| 2026-10-19 | 8. Rebuild and teardown (Task 8) | ALL PASS | Passed with Chris | Unlabel drill repeated; teardown and rebuild drill not run. |

For each row, fill in the following:

- **Date:** the day of the sitting.
- **`make verify`:** the result of the run before the walkthrough, such as `ALL PASS`.
- **Pair UAT result:** replace **Pending** with `Passed with Chris`, or with what failed. Name any
  fix made during the sitting.
- **Notes:** anything you'd want the next person to know, such as a question you couldn't answer or
  a gap you noticed. Keep host names and passwords out; this repository is public.

Then commit the runbook change.
