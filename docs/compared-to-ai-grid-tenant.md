# Compared to kahowell/ai-grid-tenant

This repository follows the layout of
[kahowell/ai-grid-tenant](https://github.com/kahowell/ai-grid-tenant) (Kevin Howell's dev cluster
configuration): `apps/<name>/` folders, a root ApplicationSet `apps`, and `gitops-config` managing
Argo CD. What differs is what the layout builds. This page explains why this repository exists,
what the original cluster can't do, and what this repository adds.

Compared on 2026-10-20: `ai-grid-tenant` `main` at `05aac4c` and this repository's `build`.

## Why a separate deployment configuration

The goal is a repeatable demo of the whole product: a provider console on an ACM hub provisions
spoke clusters, and a tenant signs in and calls a model through MaaS and the grid.

1. **The shared cluster can't be changed.** `ai-grid-tenant` is the team's dev cluster, so it
   isn't a place to try changes, tear down, or rebuild.
2. **It can't be rebuilt elsewhere.** It depends on ROSA HCP and OpenShift 4.22, and parts were
   applied by hand. A copy on demo.redhat.com (standard OpenShift 4.21) doesn't come up.
3. **The product shape is different.** The architecture is an ACM hub that provisions spokes by
   label. `ai-grid-tenant` is one cluster configured directly; its ACM manages only itself.
4. **The provider console needs a hub.** It reads ManagedClusters, placements and Keycloak on an
   ACM hub.
5. **The demo needs the whole path.** Sign-in, MaaS, the grid and a model must all work together.
6. **It must be repeatable and checkable.** Anyone with a demo.redhat.com order and a quay.io login
   should get the same environment from git, and a check suite should say whether it works.
7. **The layout stays compatible.** The team can move to this repository, or its fixes can go back
   to `ai-grid-tenant` as pull requests.

## What the original cluster can't do

1. **Reach a model through the grid.** No grid is installed; its ExternalProvider points at a
   `grid-gateway` Service that doesn't exist.
2. **Rebuild from git.** Keycloak (a community-image Deployment with Postgres, no operator) and the
   MaaS Portal's sign-in proxy, routes and AuthPolicies were applied by hand.
3. **Separate tenants from cluster users.** MaaS access is granted to `system:authenticated`, so
   anyone who can log in to the cluster is a tenant.
4. **Collect metrics.** ACM observability is crash-looping: `thanos-compact` in CrashLoopBackOff
   (read-only check, 2026-10-20). The cause is `retentionResolutionRaw: 24h`, which Thanos compact
   refuses below 40 hours, not ODF. Its OpenShift AI `ScrapeConfig` is also never collected: on ACM
   2.17 a user-workload `ScrapeConfig` reaches spokes only when the observability add-on's
   `ClusterManagementAddOn` lists it.
5. **Run off ROSA HCP or OpenShift 4.22.** The pull secret uses ROSA HCP's
   `additional-pull-secret`, and the portal uses `BackendTLSPolicy`, which OpenShift 4.21 lacks.
6. **Install its database operator on demo.redhat.com.** It installs CloudNativePG from
   `community-operators`; demo.redhat.com has it in `certified-operators`.
7. **Track current OpenShift AI.** It installs from odh-gitops branch `ai-grid`, which is the head
   of open PR [odh-gitops#203](https://github.com/opendatahub-io/odh-gitops/pull/203): one commit
   from 2026-10-09, 19 commits behind `main`. `main` has DSC v3 support (#201, which the 3.6 nightly
   uses and which renames the portal setting `dashboard.dsc.maasPortal`), the COO OperatorGroup fix
   for RHOAIENG-99507 (#202), and MaaS pull-secret fixes (#185). The grid chart work, PR 181, also
   targets `main`.
8. **Use its replicated database.** The policy that points maas-api at it is commented out, and
   maas-api can't read from a replica.
9. **Tell you whether it works.** There are no automated checks.
10. **Run on enough nodes.** On 2026-10-20 it had one 8-CPU worker (created 2026-10-19 05:11 UTC)
    and 139 pods Pending for CPU and memory, including ACM, OpenShift AI, Argo CD and the ingress
    routers; OpenShift AI's DSC was Not Ready.
11. **Protect its rate-limit Redis.** Redis has no password and is exported to other clusters.

## Improvements in this repository

### Shape and delivery

1. **Spokes provision by label.** Label a ManagedCluster `ai-grid/enabled` with an `ai-grid/role`
   (`ingress`, `inference` or `combined`), and ACM installs OpenShift AI, MaaS and the grid on it.
   Removing the label removes them in about 21 seconds.
2. **Everything is in git.** Keycloak (operator instance, realm, organizations, test users), the
   portal sign-in, the MaaS gateway setup, the grid and the console.
3. **OpenShift AI comes from odh-gitops `main`,** pinned to a commit and moved deliberately.

### The whole path works

4. **The grid is installed:** enrollment on the hub, consumer and provider on spokes, from the grid
   v0.2.1 charts. A tenant request goes from MaaS through the grid consumer and provider to vLLM.
5. **Tenant identity is separate from cluster logins:** realm `ai-grid` with Keycloak
   Organizations; tokens carry MaaS's `https://redhat.com/maas/orgs` claim.
6. **The portal sign-in is secured:** PKCE, a host-only `__Host-` cookie, only `/oauth2/start`,
   `/oauth2/callback` and `/oauth2/sign_out` public, and cross-site writes refused.
7. **The provider console runs on the hub** with the real backend, built in-cluster for
   linux/amd64. The backend's unauthenticated REST port listens on loopback only.
8. **A readiness signal:** inform-mode Policy `ai-grid-ready` (DSC Ready and the grid operator
   running) for the console to report as a cluster's provisioning state.
9. **The model fixture is ACM-placed:** `opt-125m` goes to inference spokes through an
   ApplicationSet gated on the ACM placement, the same pattern as `apps/acm-models`.

### Problems found and fixed

10. **Browsers reached the wrong service.** HTTP/2 connection reuse over a wildcard certificate sent
    Keycloak and console requests to the MaaS gateway, which answered 404. The gateway now has a
    certificate for its own host only.
11. **The portal listed no models.** MaaS needs the gateway listener's host name; Policy
    `maas-route` sets it and makes the Route passthrough.
12. **Unlabelled clusters kept their apps.** ACM leaves a stale Argo CD cluster Secret; spoke
    delivery now waits for the live ACM placement.
13. **Old settings piled up.** ACM's `musthave` never removes list items; objects whose lists
    shrink use `mustonlyhave`.
14. **Uninstalls hung.** `MaaSTenantConfig` and `AITenant` stay stuck on finalizers if OpenShift AI
    goes first; the uninstall deletes them first.
15. **Pull secrets on clusters without HCP.** An ACM Policy merges the `quay.io/rhoai` login into
    each spoke's pull secret.
16. **Grid networking on AWS.** OpenShift 4.21's AWS provider rejects a load balancer mixing UDP
    and TCP, so the grid needs one Service per protocol.

### Operations

17. **Checks:** `make verify` runs 105 checks, each with a likely cause on failure, plus lints such
    as no secrets on argv.
18. **Tested rebuilds:** `make teardown` (26 seconds) then `make all`; and
    `bootstrap/98-uninstall-spoke.sh` then a relabel, with the spoke back in under 5 minutes. Both
    passed 105 of 105.
19. **Secrets stay out of git and argv:** they come from the deployer's `.env` and travel through
    environment variables and pipes.
20. **Docs:** a [runbook](runbook.md) with timings and known gaps, and a one-sitting
    [UAT walkthrough](uat-walkthrough.md).

## Features ported from ai-grid-tenant

Built on 2026-10-20 this repository's way and tested on one cluster; `make verify` passes 145 of 145.

| Feature | Checks | How ours differs |
|---|---|---|
| Renovate | config validated | Opens a PR for the nightly catalog digest and never merges. Actions pinned by commit. Needs repository secrets `QUAY_USERNAME` and `QUAY_PASSWORD`. |
| ACM observability | `verify/08`, 14 | Thanos stores metrics in [S4](https://github.com/rh-aiservices-bu/s4), not ODF; raw retention 5 days; the OpenShift AI `ScrapeConfig` is registered with the add-on so spokes collect it, over TLS from the collector's existing exporter. |
| Submariner | `verify/09`, 8 | Delivered to every labelled spoke by placement; gateway nodes labelled by Policy. Degraded on one cluster, which has no peer. A second cluster needs the Submariner ports opened in AWS. |
| Limitador Redis | `verify/10`, 10 | Ingress spokes only; Redis and Sentinel require a password generated on the spoke, passed without argv; setup Jobs can touch only their own Secrets. |
| Replicated MaaS database | `verify/11`, 8 | Three instances on the hub, exported through Submariner, SCRAM-only logins with channel binding, and a NetworkPolicy. Remote spokes get the cross-cluster host; read replicas are groundwork because maas-api can't read from a replica yet. |

## Limits

- Tested on one OpenShift 4.21 cluster that is both hub and spoke. Multiple spokes and a rebuild on
  a fresh cluster are untested.
- Known gaps: the portal's Kubernetes-backed calls reject Keycloak tokens, tenants sign in again
  every hour, and the console returns 501 for clusters until the backend's gRPC API matches it.
