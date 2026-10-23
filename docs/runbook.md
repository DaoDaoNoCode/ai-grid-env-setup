# AI Grid demo environment runbook

## Cluster facts

Recorded by Task 1, Step 5 (read-only, 2026-10-19). Host names stay out of this public repository.

| Cluster | Role | Order | Expires | Control plane | OpenShift | Region | Nodes | Gateway API | Pre-installed operators |
|---|---|---|---|---|---|---|---|---|---|
| hub (`local-cluster`) | ACM hub and its own `combined` spoke | demo.redhat.com "OpenShift Container Platform Cluster (Multi-Cloud)", ready 2026-10-18 | 2026-11-27 | Standard (`HighlyAvailable`) | 4.21.36 | AWS `us-east-2` | 3 × `m6a.4xlarge` control plane (schedulable, worker role), 2 × `m5a.4xlarge` workers, zones a/b/c | v1.3.0 | cert-manager 1.20.1, Red Hat build of Keycloak 26.4.16 |

Run every script with `HOST_KUBECONFIG` pointing at the hub's kubeconfig file, set in the shell, never in git. Or put each cluster's API URL, user and password in the git-ignored `clusters.local.yaml` (`cp clusters.example.yaml clusters.local.yaml`, fill it in) and run `make login`: every script then reads the kubeconfigs it writes to `.kube-cache/`, and the file's `git` entry sets `GIT_REPO` and `GIT_REF`. Variables set in the shell still win.

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
| 4 | `make spokes`, then **Add to AI Grid** in the console | `make spokes` prepares spokes (pull secret, portal callbacks) and labels none. Adding a cluster in the console (Clusters) sets `ai-grid/enabled`, `ai-grid/role` and `location`; ACM then delivers the catalog, OpenShift AI, MaaS, the grid, the model and tenant intent. Dev shortcut without the console: `bash bootstrap/40-spoke.sh` | about 20 min to DSC Ready (Task 5); the rest not timed |
| 5 | `make verify` | every check in six scripts (97 on 2026-10-19) | about 2 min |

`make all` is `hub` then `spokes`; it doesn't add any cluster to the grid. Every script is safe to rerun (`make all` on the built hub,
2026-10-19: no changes, `make verify` ALL PASS).

### Moving spokes to a new nightly

Every nightly build is published as the same version, `rhods-operator.3.6.0`, so changing `catalogImage`
in `apps/ai-grid-policies/manifests/values.yaml` moves each spoke's catalog but not its operator: the
Subscription stays `AtLatestKnown` on the old build. Spokes added after the change install the new build.
On each spoke already running OpenShift AI, after its catalog `rhoai-catalog-dev` is `READY` at the new
image, delete the CSV and the Subscription together (deleting only the CSV leaves the Subscription
`UpgradePending` on its old, completed InstallPlan):

```bash
oc delete csv rhods-operator.3.6.0 -n redhat-ods-operator --wait=false
oc delete subscriptions.operators.coreos.com rhods-operator -n redhat-ods-operator
```

The spoke's `platform-<spoke>` Argo CD app recreates the Subscription and OLM installs the new build. The
DataScienceCluster and everything it deployed stay; the operator then rolls each component, so model
serving and MaaS restart briefly. On 2026-10-22 (catalog `70c700e` to `b7036647`): the new operator ran 2
to 5 minutes after the deletes, the DSC was Ready 4 to 7 minutes after them, and `make verify` passed 240
of 240 on both spokes. Upgrade an inference spoke before the ingress one. Until a spoke's operator is
replaced, its `platform-<spoke>` app can stay OutOfSync on DSC fields the old CRD doesn't have (here
`kserve.modelExpress`).

### A remote spoke, and a hub without OpenShift AI

Built 2026-10-21 on two demo.redhat.com clusters (OpenShift 4.21, AWS, same region, same pod and
Service CIDRs): the hub, and a second cluster imported as `site-a` (role `combined`). Afterwards the
hub's `local-cluster` left the grid, so the hub runs ACM, Argo CD, Keycloak, grid enrollment, the
console and the databases, and no OpenShift AI.

| Step | Command | What happens | Time |
|---|---|---|---|
| 0 | `cp clusters.example.yaml clusters.local.yaml`, add the hub and `spokes.<name>` (API URL, user, password), then `make login` | a kubeconfig per cluster in `.kube-cache/` (`host` for the hub), the API's CA embedded; no `KUBEDIR` symlinks or exports. Rerun when a token expires (a day); `make login NAMES=<name>` for one. Without `clusters.local.yaml` it stops and prints the `cp` | seconds |
| a | `make spoke-gpu SPOKE=<name>` (optional) | a GPU MachineSet cloned from one of the spoke's workers, against `$KUBEDIR/<name>` (`.kube-cache/<name>` after step 0): `GPU_INSTANCE_TYPE` (default `g6.xlarge`, NVIDIA L4), 1 replica, the clone's zone (`GPU_AZ` picks another), label `node-role.kubernetes.io/gpu`, taint `nvidia.com/gpu:NoSchedule`; waits for the node, and prints the Machine's own error if AWS refuses it (capacity, unsupported type). `DRY_RUN=1` prints the MachineSet. Remove with `make spoke-gpu-delete SPOKE=<name>`. Ported from rhoai-nightly | 5 to 15 min |
| b | `make spoke-cpu SPOKE=<name>` (optional) | the same for a CPU worker MachineSet (`CPU_INSTANCE_TYPE` `m6a.4xlarge`, `CPU_REPLICAS` 1), when the spoke needs room; `make spoke-cpu-delete` removes it | 5 to 15 min |
| c | `make spoke-infra SPOKE=<name>` | GPU node (a), plus the CPU worker (b) when `CPU=1`, then `make spoke-catalog`: the `quay.io/rhoai` auth merged into the spoke's pull secret and the nightly catalog `rhoai-catalog-dev`, READY before the Add, exactly as Policies `rhoai-pull-secret` and `rhoai-nightly-prereqs` write them. A cold catalog is unreachable for about 6 minutes, and OLM fails every Subscription on the cluster meanwhile, so after an Add on a fresh spoke Submariner and the other operators waited about 17 minutes (site-b, 2026-10-22). Skipped without `.env`. No mirror or user-workload-monitoring step: ACM Policies deliver those after the Add | – |
| d | (nothing to run) | an `inference` or `combined` spoke gets Node Feature Discovery and the NVIDIA GPU operator (app `gpu-<name>`) with its other spoke apps when it's added in the console; an `ingress` spoke gets neither. With a GPU node (a) the operator builds the driver and the node offers `nvidia.com/gpu`; without one it runs no driver or device-plugin pods and its ClusterPolicy reads `ready` (condition `NoGPUNodes`). Remove deletes the app with the others and leaves the operators installed | operators a few min, driver build on the node about 10 min |
| e | `make spoke-join SPOKE=<name>` (on the hub) | steps 1 to 3 below in one go: import, ensures `invites.<name>` and `spokes/clusters/<name>/models` (created if missing), `36-portal-clients.sh` for every spoke invited in git, plus `local-cluster` while it's a member or in `SPOKES`, less `inference` spokes (their apps domains come from the hub, so other spokes' kubeconfigs aren't needed; any other callback is dropped); then shows the `git diff --stat` of those two paths and the full diff of `values.yaml`, and asks "Commit and push to <GIT_REF>? [y/N]" (stages only them; without a terminal it prints `make spoke-commit SPOKE=<name>`, which commits and pushes them without asking) | about 1 min |
| 1 | `SPOKES="local-cluster site-a" bash bootstrap/45-import.sh` (kubeconfig at `$KUBEDIR/site-a`) | ManagedCluster `site-a`, no `ai-grid/*` labels: importing gives no grid membership and no network yet | joined 13 s |
| 2 | add `invites.<site>` to `apps/grid-enrollment/manifests/values.yaml` and `spokes/clusters/<site>/models`, commit | the invite Job mints a 24 h token; ACM delivers it to the site | about 1 min |
| 3 | `bash bootstrap/36-portal-clients.sh` | `maas-cli` takes the portal callback of every invited site | seconds |
| 4 | **Add to AI Grid** in the console (`combined`, a location) | as for `local-cluster`; membership also puts the site on Submariner with the hub (Placement `ai-grid-network` selects `ai-grid/enabled`; load-balancer mode, no AWS credentials), and the site enrolls with enrollment over it (`local-cluster.grid-enrollment.grid-enrollment.svc.clusterset.local:8443`) | tunnel up about 4 min; enrolled 72 s; Provisioned 11 min |
| 5 | `bash bootstrap/50-grid-hub-info.sh`, then commit the printed `siteDigests.<site>` | the site's provider gateway pins its own certificate (until then it pins zeros and refuses every caller) | – |
| 6 | `CONFIRM=local-cluster bash bootstrap/98-uninstall-spoke.sh local-cluster` (now `make spoke-uninstall SPOKE=local-cluster REVOKE_TENANT_KEYS=1` while `site-a` is `combined`: it revokes every tenant API key), then `SPOKES=site-a bash bootstrap/36-portal-clients.sh` | the hub leaves the grid and drops OpenShift AI; its Submariner, `maas-db` and `grid` stay | 159 s |
| 7 | `SPOKES=site-a SPOKE_ROLES=site-a=combined SPOKE_LOCATIONS=site-a=us-east make verify` | 177 checks (221 with both spokes) | about 3 min |

`invites.site-a` (`apps/grid-enrollment/manifests/values.yaml`) and `siteDigests.site-a`
(`apps/ai-grid-spokes/manifests/values.yaml`) are values from this build, like `hubSiteDigest`. On a
rebuild, replace them as steps 2 and 5 say: until then the invite names a cluster that may not exist,
and the provider gateway pins a stale digest and refuses every caller.

Spokes reach the hub's exports at `local-cluster.<svc>.<ns>.svc.clusterset.local`, Lighthouse's
name for the hub's own export, so another member exporting a Service of the same name can't answer
for it. Enrollment's serving certificate names it through `serving.extraDnsNames`; the bootstrap Job
that issues the certificate is a hook, and Argo CD runs hooks only when something else changed, so
after changing that value sync `grid-enrollment` by hand and restart `deploy/grid-enrollment`
(`verify/05` checks the name).

What a remote spoke needed that `local-cluster` never did, each now in git with a check:
Lighthouse imports a Service only into a namespace that exists on the importing cluster (Policy
`clusterset-namespaces`); maas-api's own egress policy admits 5432 only to in-cluster postgres
(Policy `maas-db` adds the hub database's Globalnet address); the Cluster Observability Operator
(the platform app installs it on every spoke but `local-cluster`); Argo CD must know a cluster
before an ApplicationSet can target it (GitOpsCluster follows `ai-grid-network`); the grid chart's
invite Policy deadlocks Argo CD's PostSync hooks (a Policy health check); odh-model-controller's
stale `<gateway>-authn-ssl` EnvoyFilters (Policy `authorino-service-ca` removes them); and Argo CD's
controller needs 8Gi once it caches a second cluster.

### An inference site served through another site's MaaS

Not yet built. An `inference` spoke runs OpenShift AI, the grid provider and the model, and no MaaS
or consumer. A tenant request enters an `ingress` or `combined` spoke's MaaS, whose consumer gateway
calls the inference site's provider over the grid's mutual TLS through Submariner. The gateways
refuse host names, and a clusterset name resolves private, so the consumer dials the inference
site's exported provider Service (`spokes/grid/provider-export`) at its Globalnet address, a literal
`242.x` IP that changes on every build.

| Step | Command | What happens |
|---|---|---|
| 1 | import, invite and `spokes/clusters/<site>/models` as steps 1–3 above | as for `site-a` |
| 2 | nothing: `remoteSwimServiceType` in `apps/ai-grid-spokes/manifests/values.yaml` is `LoadBalancer` (set `ClusterIP` only for a single remote site, to skip the NLB) | remote sites gossip with each other through an NLB |
| 3 | **Add to AI Grid** in the console, role `inference` | OpenShift AI, the grid operator and provider, the model, and ApplicationSet `grid-provider-export`, which exports `grid-provider-fixed`; Globalnet gives it a GlobalIngressIP |
| 4 | `bash bootstrap/50-grid-hub-info.sh`, then commit the printed `siteDigests.<site>` and `providerGlobalIPs.<site>`, and list every ingress and combined spoke in `consumerSites` | every other site's consumer lists the site as a backend at that address; the site's provider pins exactly the `consumerSites` digests; its grid operator advertises that address |
| 5 | `make verify` | `verify/05` checks the export's address against git, each consumer's backend, and both lists against the spokes' roles. Stopping only the model doesn't move traffic: the consumer health-checks provider gateways over TCP, so a site whose provider is up keeps being chosen and answers 502 (demo1, 2026-10-22: site-a's model at 0 replicas, 4 of 4 requests still went to site-a). Proving the route with `E2E_EXPECT_SITE=<site> bash verify/06-tenant-e2e.sh` is pending a choice: a model served only on the inference site, or the entry spoke's grid provider stopped (unverified that `intelligent_route` then skips that site) |

`providerGlobalIPs.<site>` is a value from this build, like `siteDigests`: on a rebuild, replace it
as step 4 says. An `ingress` spoke has no provider of its own, so it needs at least one
`providerGlobalIPs` entry (with none, its consumer's values fail the chart's schema).

The provider has no NetworkPolicy, so traffic from another cluster (Globalnet SNATs it to that
cluster's `242.x` egress address, so a namespaceSelector couldn't match it) reaches it; the mutual
TLS and the pinned digests decide who's served. A NetworkPolicy would need the local consumer, the
grid operator's probe, and an ipBlock for the callers' Globalnet range.

To check on a cluster first: that Globalnet names the export's GlobalIngressIP `grid-provider-fixed`
(after the Service, as `maas-db-rw`'s is); that the gateway takes a `242.x` literal as a backend and its TCP
health check reaches it; that MaaS passes `X-Grid-Provider-Site` back to the caller; that the inference site's operator can reach its own Globalnet address if it
probes the advertised one; and that an ingress spoke's operator enrolls and creates
`grid-site-identity`, which its consumer presents.

**Teardown** (`make teardown`) stops delivery and leaves what it installed: it unlabels the spokes,
deletes the root ApplicationSet, then everything the delivery apps `ai-grid-spokes` and
`ai-grid-policies` created (found by Argo CD's tracking annotation), then those apps. No Application
has a resources finalizer except a remote spoke's `submariner-<site>` (leaving the network removes
Submariner from that spoke, as Remove in the console does), every ApplicationSet preserves resources
on deletion, and ACM Policies don't prune, so OpenShift AI, the grid and the hub services keep
running. Not yet run on `aio`.

**Unlabel drill** (Task 8 Step 4, 2026-10-19): removing `ai-grid/enabled` from `local-cluster`
removed its six delivery Applications within 21 s and its Policies; the DSC stayed Ready and the grid
gateways, model and maas-api kept running. Relabelling restored all six Applications in 31 s and
`make verify` passed. The first run failed: Argo CD's cluster Secret keeps the labels it was created
with, so the Applications stayed. The spoke ApplicationSets now take membership from ACM's placement
`ai-grid-spokes` (a `clusterDecisionResource` matrix). The role still comes from the cluster Secret's
labels, so changing a spoke's role may need its Secret refreshed (untested).

**Spoke uninstall** (`make spoke-uninstall SPOKE=<spoke>`, which asks you to type the name at a terminal;
without one, add `CONFIRM=<spoke>`): removes a spoke's AI Grid layer so relabelling provisions it from zero.
Run it instead of Remove in the console, not after it: it reads the spoke's Applications, which Remove
deletes. If Remove came first, it stops and says to add the spoke again, wait for its apps to sync, and rerun.
A remote spoke keeps its route to the hub's `maas-db` (label `ai-grid/uninstalling`, which Placement
`ai-grid-network` also selects) until MaaS's cleanup is done. MaaS's objects go in order: subscriptions,
then the AITenant, whose cleanup revokes the tenant's API keys in the hub's `maas-db` and then deletes its
MaaSTenantConfig. Namespace `ai-tenants` stays until then. Only then does the spoke leave the network and drop
its `maas-db` replica. A run that stops leaves the label and says so: rerun, or remove it on the hub with
`oc label managedcluster <spoke> ai-grid/uninstalling-`. The AITenant's cleanup revokes **every**
API key of the tenant, so on an `ingress` or `combined` spoke the script stops while another `ingress` or
`combined` spoke is a member, unless you add `REVOKE_TENANT_KEYS=1`. It saves the Applications' inventory to
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

**Rebuild drill** (Task 8 Step 5): not run. It needs a fresh demo.redhat.com order and PR 1 merged
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
| 2026-10-19 | 9. Provider console, as is (Task 9) | ALL PASS (07-console) | **Pending** | Built on the hub from pinned commits (console `ac80c25`, backend `dd513f9`, linux/amd64) into the internal registry; provider admins sign in with the cluster login (OAuthClient from `bootstrap/60-console.sh`); the backend uses its own Keycloak user in realm `ai-grid`. Clusters and Organizations answered 501 until the console and backend gRPC names matched (console PR 34, backend PR 12); `verify/07` now requires 200. Rebuild: bump the refs in `apps/console/manifests`, then `oc start-build` and `oc rollout restart`. Images (2026-10-20): by default `ghcr.io/ai-grid-cloud/ai-grid-provider-console` and `ghcr.io/ai-grid-cloud/ai-grid-provider-backend`, pinned by `sha-<full commit>@<digest>` in `apps/console/manifests/images/ghcr/` (tags can be overwritten; the digest is what runs) (the packages the repositories' GitHub Actions publish from `main`, console PR 32 and backend PR 8). **Bump:** take the `sha-<commit>` tag CI published for the merge commit and its digest (`skopeo inspect docker://<image>:<tag> | jq -r .Digest`), change both in `images/ghcr/kustomization.yaml`, move the base ref in `apps/console/manifests/kustomization.yaml` and the refs in `builds.yaml` to the same commits, commit; Argo CD rolls the pod. Never pin `latest` or `pr-<N>`. **Fallback** for unpublished work: set the `components:` line to `./images/in-cluster` and build with the BuildConfigs in `builds.yaml` (`*-local` take a local checkout). The backend may patch ManagedCluster labels (Add to AI Grid, Remove) and get only the root Policy `ai-grid-ready` (Role in `apps/ai-grid-policies`): the per-cluster Policy copies hold rendered hub-template secrets. |
| 2026-10-20 | 10. Features from `ai-grid-tenant` (parity plan) | ALL PASS (145) | **Pending** | Renovate (PRs only, for the nightly catalog digest; needs repository secrets `QUAY_USERNAME` and `QUAY_PASSWORD`). ACM observability on the hub with Thanos in S4, and OpenShift AI metrics from spokes (`verify/08`). Submariner add-on with Globalnet on every spoke (`verify/09`; Degraded on one cluster, which has no peer). Limitador counters in password-protected Redis on ingress spokes (`verify/10`). maas-db with 3 instances, exported through Submariner, SCRAM-only logins, and a NetworkPolicy; read replicas for remote ingress spokes as groundwork (`verify/11`). `98-uninstall-spoke.sh` covers the new pieces but hasn't been rerun. |


## Sample model (fixture)

`spokes/models/opt-125m` and `spokes/tenant/` (opt-125m, its ExternalModel and MaaSModelRef, and the
opt-125m-org1 subscription) are a smoke-test fixture for `verify/06-tenant-e2e.sh`. The provider
console replaces them once it deploys models and creates subscriptions; then they're deleted. The
model plumbing (the grid-backend Service, NetworkPolicy allow-grid-provider) stays.

## Known gaps

- **Image and chart trust.** Container images are pinned by digest: the console and backend in
  `apps/console/manifests/images/ghcr/`, the grid gateway by `gridGatewayDigest` in
  `apps/ai-grid-spokes/manifests/values.yaml`. The grid's OCI Helm charts (grid-operator,
  praxis-gateway, grid-enrollment 0.2.0) are trusted by version only: Argo CD can't pin an OCI Helm
  chart by digest, so a re-pushed chart version would be picked up.
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
- **On one cluster, `submariner-<spoke>` shows Degraded in Argo CD.** Submariner's
  ManagedClusterAddOn reports "There are no connections on gateways" until a second cluster joins.
  That's expected, not a fault.
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
- **Removing an unreachable spoke can leave its Submariner app stuck deleting.** Remove makes Argo CD
  delete `submariner-<spoke>`, whose resources finalizer waits for the add-on and SubmarinerConfig to
  go; ACM's cleanup of them may never finish while the spoke can't be reached. Unstick it on the hub:
  `kc host delete managedclusteraddon submariner -n <spoke> --wait=false`, then, if the app still
  hangs, `kc host patch applications.argoproj.io submariner-<spoke> -n openshift-gitops --type json
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'`. Remove taking a spoke off the network is
  designed but not yet verified on a cluster.
- **GPU operators: what's still unverified.** `spokes/gpu` ran on a g6.xlarge (L4) spoke on 2026-10-21: NFD found the card, the operator built driver 580.105.08, the ClusterPolicy reached `ready`, and the node offered `nvidia.com/gpu: 1`. Not run: g6e (L40S) nodes. The DCGM ServiceMonitor is scraped only with the label `openshift.io/cluster-monitoring=true` on namespace `nvidia-gpu-operator`, which nothing sets.
- **Metrics have one copy.** S4 runs one replica on one volume; losing the volume loses stored metrics.
- **The MaaS gateway calls Authorino in plaintext.** The MaaS install guide turns TLS on for
  Authorino's listener (`setup-authorino-tls.sh`), and odh-model-controller's `<gateway>-authn-ssl`
  EnvoyFilter then makes the gateway use it; here Policy `authorino-service-ca` deletes that filter
  instead, and maas-controller reports the tenant `Degraded` ("Authorino TLS is not configured").
  Setting the chart's `dependencies.rhcl.config.tlsEnabled` alone would stall a new spoke: the
  authorino operator checks the listener's certificate Secret before it creates Service
  `authorino-authorino-authorization` (`installationPreflightCheck`), and the service CA issues that
  Secret only for an annotation on that Service. Turning TLS on needs the steps in order: Authorino up
  in plaintext, the Service annotated, the Secret issued, then the listener's TLS on (the Kuadrant
  operator keeps it on), the `mustnothave` rules for `<gateway>-authn-ssl` dropped from Policy
  `authorino-service-ca` (and verify/04's plaintext check reversed), then a Gateway event so
  odh-model-controller adds the filter (it decides on Gateway events only; restarting it reconciles
  them all). Keep this repository's `SSL_CERT_DIR`, which adds the service CA to Authorino's trust
  without changing which bundle file it reads; the guide's script sets `SSL_CERT_FILE` to the service
  CA alone instead.
- **A catalog bump can stop ExternalModel traffic.** From ai-gateway-controller
  [#151](https://github.com/opendatahub-io/ai-gateway-controller/pull/151), the controller writes new
  Praxis filter names into the ExternalModel ExtProc's configuration even with
  `MaasTenantConfig.spec.apiTranslation.enabled` off; an ExtProc image without those filters rejects
  the pipeline (`NotServing`), and every grid model on an ingress spoke stops answering. Before moving
  `catalogImage`, check that the nightly's ai-gateway-controller and Praxis ExtProc match
  (`verify/06-tenant-e2e.sh` "completion 200" fails on a broken one).
- **A streamed completion without usage isn't counted.** A request with `"stream": true` and no
  `stream_options.include_usage` gets no `usage` in its response, so Limitador never counts its tokens,
  whether `RATELIMIT_REPORT_SERVICE_FAILURE_MODE` is `allow` or `deny`. Seen 2026-10-22 on OpenShift AI 3.6
  nightly (RHCL 1.4.3) with the MaaS simulator sample at 100 tokens a minute: twelve plain requests,
  then 429; twenty such streams all 200, and plain requests still 200 afterwards. MaaS v0.2.1's release
  notes list `include_usage` as enforced in the IPP pipeline, but this nightly's payload-processing
  chain runs only `request_id`.

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
- Kuadrant fails open by default (kuadrant-operator `internal/wasm/utils.go`): with Limitador
  unreachable, the gateway passes requests and their tokens go uncounted. Ingress spokes set
  `RATELIMIT_CHECK_SERVICE_FAILURE_MODE` and `RATELIMIT_REPORT_SERVICE_FAILURE_MODE` to `deny` on the
  rhcl-operator Subscription, and `AUTH_SERVICE_TIMEOUT` to `2s` (the 200ms default shows as
  intermittent 500s under load), as the MaaS install guide recommends (`platform-setup.md`). With
  Limitador unreachable, a completion then gets 500 instead of reaching the model. Kuadrant's
  token-rate-limiting guide warns that report `deny` can block a response whose usage it can't read;
  on RHCL 1.4.3 with Limitador up, a stream without usage still answered 200 (see Known gaps).

## Known overrides of operator-owned objects

- **Authorino Deployment** (`kuadrant-system/authorino`): Policy `authorino-service-ca` adds env `SSL_CERT_DIR` and, through the Authorino CR, a service-CA volume, so Authorino can call maas-api over HTTPS. The authorino operator owns the Deployment. If the Policy's compliance history flips between NonCompliant and Compliant (`kc host get policy ai-grid-policies.authorino-service-ca -n local-cluster -o yaml`, `status.details[].history`), the operator is reverting it.
- **MaaS gateway** (`openshift-ingress`): Policy `maas-route` owns its parameters ConfigMap (ClusterIP Service, and a CA bundle from Policy `maas-gateway-ca` mounted over the proxy's CA file), sets the `https` listener's host name `maas.<apps domain>` (Argo CD ignores that field), requests a cert-manager certificate for `maas.<apps domain>` only (`maas-gw-public-tls`, from the issuer of the router's own certificate; a copy of the router's certificate where cert-manager didn't issue it), and owns the passthrough Route. A wildcard certificate here would let browsers reuse the gateway's HTTP/2 connection for Keycloak and the console, which the gateway answers with 404.
- **Limitador** (`kuadrant-system/limitador`): Argo CD sets only `spec.storage` server-side, pointing it at
  the spoke's Redis; Kuadrant owns the rest, and teardown never deletes it.
- **ACM observability add-on** (`ClusterManagementAddOn multicluster-observability-addon`): Policy
  `rhai-metrics-hub` adds the `rhai-metrics` ScrapeConfig to its configs with `musthave`.
