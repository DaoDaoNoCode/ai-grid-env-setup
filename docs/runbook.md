# AI Grid demo environment runbook

## Cluster facts

Recorded by Task 1, Step 5 (read-only, 2026-10-19). Host names stay out of this public repository.

| Cluster | Role | Order | Expires | Control plane | OpenShift | Region | Nodes | Gateway API | Pre-installed operators |
|---|---|---|---|---|---|---|---|---|---|
| hub (`local-cluster`) | ACM hub and its own `combined` spoke | demo.redhat.com "OpenShift Container Platform Cluster (Multi-Cloud)", ready 2026-10-18 | 2026-11-27 | Standard (`HighlyAvailable`) | 4.21.36 | AWS `us-east-2` | 3 × `m6a.4xlarge` control plane (schedulable, worker role), 2 × `m5a.4xlarge` workers, zones a/b/c | v1.3.0 | cert-manager 1.20.1, Red Hat build of Keycloak 26.4.16 |

Run every script with `HOST_KUBECONFIG` pointing at the hub's kubeconfig file, set in the shell, never in git.

## Access

Who can use the hub is per environment, so it isn't in git. `bootstrap/00-gitops.sh` makes the
person who runs it an Argo CD admin (OpenShift group `cluster-admins`, which Argo CD maps to
`role:admin`). To give someone else access, once they can log in to the cluster:

```bash
oc adm groups add-users cluster-admins <user>                           # Argo CD admin
oc adm policy add-cluster-role-to-user cluster-admin <user>              # cluster-admin, if needed
```

Remove them with `oc adm groups remove-users cluster-admins <user>` and
`oc adm policy remove-cluster-role-from-user cluster-admin <user>`.

## Build, rebuild, and tear down

Prerequisites: `oc`, `helm`, `jq`, `curl` and `openssl`; a cluster-admin login to the hub in the file
`HOST_KUBECONFIG` names; and a `quay.io/rhoai` login in podman (`hack/quay-env.sh` copies it into the
git-ignored `.env`). demo.redhat.com's OpenShift order already has cert-manager and the Red Hat build of
Keycloak operator; the GitOps operator subscribes to channel `latest`, unpinned; the grid's fixed
backend addresses (`modelBackendIP`, `providerIP`) assume the default `172.30.0.0/16` service network.

| Step | Command | What happens | Time on `aio` |
|---|---|---|---|
| 1 | `bash hack/quay-env.sh` | Writes `.env` (once per machine) | seconds |
| 2 | `make hub` | GitOps, then Argo CD builds the hub from `apps/*` (ACM, maas-db, Keycloak, grid enrollment, Policies); Keycloak users and the hub facts ConfigMap | first build not timed (it ran in stages during Tasks 2–4); a rerun 17 s |
| 3 | commit `hubSiteDigest` | `50-grid-hub-info.sh` prints it; a new hub has a new grid CA (D8) | – |
| 4 | `make spokes` | Labels each spoke; ACM delivers the pull secret, catalog, OpenShift AI, MaaS, the grid, the model and tenant intent; adds portal callbacks | about 20 min to DSC Ready (Task 5); the rest not timed |
| 5 | `make verify` | every check in six scripts (97 on 2026-10-19) | about 2 min |

`make all` is `hub` then `spokes`. Every script is safe to rerun (`make all` on the built hub,
2026-10-19: no changes, `make verify` ALL PASS).

**Teardown** (`make teardown`) stops delivery and leaves what it installed: it unlabels the spokes,
deletes the root ApplicationSet, then everything the delivery apps `ai-grid-spokes` and
`ai-grid-policies` created (found by Argo CD's tracking annotation), then those apps. No Application
has a resources finalizer, every ApplicationSet preserves resources on deletion, and ACM Policies
don't prune, so OpenShift AI, the grid and the hub services keep running. Not yet run on `aio`.

**Unlabel drill** (Task 8 Step 4, 2026-10-19): removing `ai-grid/enabled` from `local-cluster`
removed its six delivery Applications within 21 s and its Policies; the DSC stayed Ready and the grid
gateways, model and maas-api kept running. Relabelling restored all six Applications in 31 s and
`make verify` passed. The first run failed: Argo CD's cluster Secret keeps the labels it was created
with, so the Applications stayed. The spoke ApplicationSets now take membership from ACM's placement
`ai-grid-spokes` (a `clusterDecisionResource` matrix). The role still comes from the cluster Secret's
labels, so changing a spoke's role may need its Secret refreshed (untested).

**Spoke uninstall** (`CONFIRM=<spoke> bash bootstrap/98-uninstall-spoke.sh <spoke>`): removes a spoke's AI
Grid layer so relabelling provisions it from zero. It saves the Applications' inventory to
`out/uninstall-<spoke>.txt` before unlabelling (a rerun reuses it), deletes tenant intent, the model and
the grid's objects, then the MaaS objects that carry cleanup finalizers while OpenShift AI's controllers
still run, then OpenShift AI and MaaS, their operators, the nightly catalog and the namespaces. It keeps
the hub's services and grid site identity (`grid` stays on `local-cluster`), the node pull secret and
image mirror (changing them reboots nodes), cert-manager and CRDs.

**Rebuilds on `aio`** (2026-10-19/20):
- Delivery rebuild: `make teardown` (26 s; every Application and Policy gone, workloads and the tenant
  end-to-end path still working), then `make all`: 14/14 apps healthy, all Policies Compliant,
  `make verify` 105/105.
- Spoke rebuild: the uninstall above, then `bash bootstrap/40-spoke.sh`: the OpenShift AI operator
  installed in 2 min, DSC Ready at 3.5 min, all six spoke apps healthy at under 5 min, `make verify`
  105/105. Faster than the first build (about 20 min) because images, CRDs and the node pull secret
  were already there. The first uninstall run stopped on two script bugs, both fixed: tab-separated
  inventory fields collapsed, and MaaSTenantConfig and AITenant kept their cleanup finalizers after
  their controllers were removed (now deleted first; this run's two finalizers were cleared by hand).

**Rebuild drill** (Task 8 Step 5): not run. It needs a fresh demo.redhat.com order and `build` merged
to `ai-grid-cloud/ai-grid-env-setup` `main`.

**Expiry.** The `aio` order expires 2026-11-27. Extend it from the order's page in demo.redhat.com
before then (how long an extension lasts is set there; unverified).

**Adding a spoke** is Task 11 of the plan (import, labels, invite) and untested here.

**Demo script**: waits for the provider console (Task 9, on hold).

## UAT log

| Date | Checkpoint | `make verify` | Pair UAT result | Notes |
|---|---|---|---|---|
| 2026-10-19 | 1. Hub platform (Task 2) | ALL PASS | Passed with Chris. Fixed during UAT: Argo CD showed nothing (deployer not in group `cluster-admins`); the hub moved to Argo CD apps (`apps/*`); access kept out of git. Database kept on CloudNativePG (persistent 20Gi gp3; no backups, no `Delete=false` guard, by choice). | Console perspective is "Fleet management" in ACM 2.17; CloudNativePG pods show under Pods, not Workloads. |
| 2026-10-19 | 2. Keycloak (Task 3) | ALL PASS | **Pending** (Chris away; built autonomously) | Realm ai-grid: org1/org2, alice/dave/bob, maas orgs claim verified in tokens; own CloudNativePG database; Route maas-keycloak (demo Keycloak untouched). |
| 2026-10-19 | 3. Grid enrollment (Task 4) | ALL PASS | **Pending** (Chris away) | grid-enrollment 0.2.0 on the hub; hub site local-cluster via hubSite; no Route until a remote spoke (D8); bootstrap hook reruns on every sync and keeps the CA (verified). |
| 2026-10-19 | 4. Spoke delivery (Task 5) | ALL PASS | **Pending** (Chris away) | Labelling local-cluster provisioned it through ACM: Placements, GitOpsCluster, Policies (pull secret, nightly catalog, maas-db, tenant OIDC, maas-route, ai-grid-ready Compliant), OpenShift AI 3.6 DSC Ready in ~20 min, MaaS health 200 at maas.<apps domain>, grid operator running. Pull-secret path: ACM Policy (D4), after fixing ACM auto-encryption of hub fromSecret. |
| 2026-10-19 | 5. Models and tenant intent (Task 6) | ALL PASS | **Pending** (Chris away) | opt-125m Ready on local-cluster (with a minimal chat template); grid path consumer → mTLS → provider → model returns 200 for chat; MaaS ExternalProvider/ExternalModel/MaaSModelRef Ready, org1-group1 subscription and auth policy Active. One InferenceProvider (ours). PR 966: downstream rhoai-3.6 has diverged from the merge and the installed controller has no InferenceProvider rights, so the nightly doesn't publish providers (as expected). |
| 2026-10-19 | 6. Tenant end to end (Task 7, Steps 1-3) | ALL PASS (06-tenant-e2e) | **Pending** (Chris away) | alice: Keycloak (hub) → MaaS on local-cluster (key minted) → MaaS gateway → grid consumer (TLS) → mTLS → provider → vLLM: 200 with text. dave (org1, no group) refused, but MaaS answers 500 AUTH_FAILURE rather than 403 (upstream bug to report). Portal sign-in followed in Steps 5-6 (row 7). |
| 2026-10-19 | 7. Tenant portal sign-in (Task 7, Steps 5-6) | ALL PASS (06-tenant-portal) | **Pending** (Chris away) | D6 as re-decided: alice opens `https://maas.<apps domain>/maas-consumer-portal/`, is sent to hub Keycloak realm ai-grid, signs in (user name, then password), and the portal opens; the cluster's OpenShift login lists only `rhbk`. Policy `tenant-portal` delivers an oauth2-proxy (namespace `aigrid-portal-auth`), two HTTPRoutes on the MaaS gateway, and Authorino policies. The proxy uses the public tenant client `maas-cli` with PKCE, because MaaS accepts one client per tenant. Cross-origin cookie writes are refused (CSRF fix, RED→GREEN). The portal lists alice's models once Policy `maas-route` gives the MaaS gateway its host name (fixed the same night). Open gap: the portal's Kubernetes-backed calls (user, namespaces) are Unauthorized for Keycloak tokens. |
| 2026-10-19 | 8. Rebuild and teardown (Task 8) | ALL PASS | **Pending** (one sitting at the end) | Unlabel drill passed (apps removed in 21 s, workloads kept, relabel restored in 31 s) after the placement-gated ApplicationSets fix. `make teardown` not run. Rebuild drill needs a fresh order. |
| 2026-10-19 | 9. Provider console, as is (Task 9) | ALL PASS (07-console) | **Pending** | Built on the hub from pinned commits (console `ac80c25`, backend `dd513f9`, linux/amd64) into the internal registry; provider admins sign in with the cluster login (OAuthClient from `bootstrap/60-console.sh`); the backend uses its own Keycloak user in realm `ai-grid`. Clusters and Organizations answer 501 until the console and backend gRPC names match. Rebuild: bump the refs in `apps/console/manifests`, then `oc start-build` and `oc rollout restart`. |
| 2026-10-20 | 10. Features from `ai-grid-tenant` (parity plan) | ALL PASS (145) | **Pending** | Renovate (PRs only, for the nightly catalog digest; needs repository secrets `QUAY_USERNAME` and `QUAY_PASSWORD`). ACM observability on the hub with Thanos in S4, and OpenShift AI metrics from spokes (`verify/08`). Submariner add-on with Globalnet on every spoke (`verify/09`; Degraded on one cluster, which has no peer). Limitador counters in password-protected Redis on ingress spokes (`verify/10`). maas-db with 3 instances, exported through Submariner, SCRAM-only logins, and a NetworkPolicy; read replicas for remote ingress spokes as groundwork (`verify/11`). `98-uninstall-spoke.sh` covers the new pieces but hasn't been rerun. |


## Sample model (fixture)

`spokes/models/opt-125m` and `spokes/tenant/` (opt-125m, its ExternalModel and MaaSModelRef, and the
opt-125m-org1 subscription) are a smoke-test fixture for `verify/06-tenant-e2e.sh`. The provider
console replaces them once it deploys models and creates subscriptions; then they're deleted. The
model plumbing (the grid-backend Service, NetworkPolicy allow-grid-provider) stays.

## Known gaps

- **MaaS keeps a stale model URL.** maas-controller writes a MaaSModelRef's `status.endpoint` when the
  model reconciles and doesn't watch the Gateway, so a model created before Policy `maas-route` set the
  listener host name keeps the in-cluster address. maas-ui likewise caches a failed `/v1/tenants`
  lookup. Fix: delete the `maas-controller` and `maas-ui` pods in `redhat-ods-applications`
  (`verify/06-tenant-e2e.sh` "model URL is public" and `06-tenant-portal.sh` "portal lists alice's
  models" catch both).
- **Portal Kubernetes-backed calls** (`/api/v1/user`, `/maas/api/v1/namespaces`): the portal's BFFs
  check the forwarded token against the cluster API, which doesn't trust Keycloak tokens, so these
  answer 401 or 500. Making the API trust Keycloak means changing cluster authentication, which D6
  rules out.
- **A second cluster needs Submariner's AWS ports.** ACM can't prepare the AWS security groups
  without an AWS credentials Secret (`SubmarinerClusterEnvironmentPrepared=False`), so open IPsec
  (UDP 500 and 4500) and the Submariner ports between the clusters by hand, or give ACM credentials.
- **The cross-cluster database login isn't certificate-verified.** A remote spoke's maas-api connects
  to `maas-db-rw.maas-db.svc.clusterset.local` with `require_auth=scram-sha-256` and
  `channel_binding=require`, so an impostor can't complete the login and never sees the password.
  `verify-full` would need the hub's CA as a file in the operator-owned maas-api pod.
- **maas-api can't use a read replica,** and its egress NetworkPolicy may block a remote spoke from
  reaching the hub's Globalnet address. The replica pieces are groundwork until both change.
- **Before the first remote ingress spoke, harden the replica groundwork** (security review,
  2026-10-20; none of it runs on one cluster): Policy `maas-db-replication` copies the app login as
  well as the replication certificate to each remote spoke (copy only what the replica needs); the
  replica in `spokes/maas-db-replica` has no NetworkPolicy; and the hub's `maas-db-ingress` admits
  all of Globalnet `242.0.0.0/8`, so any cluster in the set can reach port 5432 (narrow it to the
  ingress spokes' Globalnet CIDRs).
- **Metrics have one copy.** S4 runs one replica on one volume; losing the volume loses stored metrics.

## Fixes found along the way

Each is in git with a comment where it applies; the plan's ledger has the detail.

- ACM 2.17 auto-encrypts hub-template `fromSecret` output: decode on the managed side
  (`| base64dec`), never add `protect`.
- ACM `musthave` merges list items by `name`, so a Policy can set one field of one Gateway listener.
  It also never removes list items: an object whose lists shrink (the portal proxy's `args`) uses
  `mustonlyhave`, and a route whose `matches` shrink is replaced under a new name (`mustnothave` on
  the old one).
- Argo CD's Lua health checks have no `string` library; on an ACM hub `oc get application` means
  ACM's kind (use `applications.argoproj.io`).
- Helm charts that hold ACM or ApplicationSet templates escape them as raw strings (``{{`{{...}}`}}``);
  `verify/04-spokes.sh` lints for it.
- CloudNativePG on demo.redhat.com comes from `certified-operators`; maas-api's egress NetworkPolicy
  admits only pods labelled `app=postgres`.
- Keycloak realm import replaces the built-in client scopes and drops unmanaged user attributes;
  `35-keycloak.sh` restores `sub`, `preferred_username` and `maas_orgs`.
- MaaS: the AITenant needs `spec.gateway.name`; Authorino needs the service CA to call maas-api; the
  gateway needs a CA bundle to reach the grid consumer over TLS; this nightly's ExternalProvider
  accepts only apikey auth and always dials HTTPS 443; MaaS routes by its own model ID, so the model
  is named `facebook-opt-125m` end to end; a valid user with no groups gets 500, not 403.
- AWS load balancers carry no UDP, so the single-site grid's gossip Service is ClusterIP. An AWS
  Network Load Balancer does carry UDP on demo.redhat.com (a UDP-only `LoadBalancer` Service with the
  `nlb` annotation answered from the internet after about 4 minutes), but OpenShift 4.21's AWS
  provider rejects a `LoadBalancer` Service that mixes UDP and TCP, so each protocol needs its own
  Service.
- The portal's sign-in proxy can't hand a refreshed session back to the browser (Authorino calls it
  on the browser's behalf), so a session lasts the `maas-cli` client's 1-hour token; then the tenant
  signs in again.
- opt-125m has no chat template; KServe renders the LLMInferenceService through Go templates, so the
  template is escaped with raw strings.

- ACM observability: Thanos compact refuses raw retention under 40 hours, so `retentionResolutionRaw:
  24h` (as on `ai-grid-tenant`) crash-loops `thanos-compact`; this repository keeps 5 days. On ACM
  2.17 a user-workload `ScrapeConfig` reaches spokes only when `ClusterManagementAddOn
  multicluster-observability-addon` lists it (Policy `rhai-metrics-hub`). This nightly's OpenShift AI
  collector already uses port 8890 internally, so metrics are scraped from its exporter on 8889.
- Setup Jobs that fill a Secret patch it through stdin: `oc apply` keeps a copy of the data in its
  `last-applied-configuration` annotation.

## Known overrides of operator-owned objects

- **Authorino Deployment** (`kuadrant-system/authorino`): Policy `authorino-service-ca` adds env `SSL_CERT_DIR` and, through the Authorino CR, a service-CA volume, so Authorino can call maas-api over HTTPS. The authorino operator owns the Deployment. If the Policy's compliance history flips between NonCompliant and Compliant (`kc host get policy ai-grid-policies.authorino-service-ca -n local-cluster -o yaml`, `status.details[].history`), the operator is reverting it.
- **MaaS gateway** (`openshift-ingress`): Policy `maas-route` owns its parameters ConfigMap (ClusterIP Service, and a CA bundle from Policy `maas-gateway-ca` mounted over the proxy's CA file), sets the `https` listener's host name `maas.<apps domain>` (Argo CD ignores that field), requests a cert-manager certificate for `maas.<apps domain>` only (`maas-gw-public-tls`, from the issuer of the router's own certificate; a copy of the router's certificate where cert-manager didn't issue it), and owns the passthrough Route. A wildcard certificate here would let browsers reuse the gateway's HTTP/2 connection for Keycloak and the console, which the gateway answers with 404.
- **Limitador** (`kuadrant-system/limitador`): Argo CD sets only `spec.storage` server-side, pointing it at
  the spoke's Redis; Kuadrant owns the rest, and teardown never deletes it.
- **ACM observability add-on** (`ClusterManagementAddOn multicluster-observability-addon`): Policy
  `rhai-metrics-hub` adds the `rhai-metrics` ScrapeConfig to its configs with `musthave`.
