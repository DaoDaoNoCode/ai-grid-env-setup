# ai-grid-env-setup

Builds a rebuildable AI Grid demo environment: an ACM hub (ACM, Argo CD, Keycloak, grid enrollment,
the provider console) that provisions labelled spoke clusters with OpenShift AI, MaaS, and the grid
from the [odh-gitops](https://github.com/opendatahub-io/odh-gitops) chart.

- `env.sh`: every setting and pin, sourced by all scripts.
- `bootstrap/`: idempotent scripts for the steps that carry secrets or run before Argo CD.
- `verify/`: user-level checks; `make verify` runs them all.
- `docs/runbook.md`: cluster facts, access, and the UAT log.
- Sample model (fixture): `spokes/models/opt-125m` and `spokes/tenant/` (opt-125m, its MaaS model and the org1 subscription) exist only so `verify/06-tenant-e2e.sh` has a model to call; they're deleted once the provider console deploys models and creates subscriptions.

## Quick start

On a demo.redhat.com OpenShift 4.21 or later cluster, with a cluster-admin login and a `quay.io/rhoai`
podman login from a read-only robot account, since the login is copied to every spoke's pull secret
(details and timings in [the runbook](docs/runbook.md#build-rebuild-and-tear-down)):

```bash
export HOST_KUBECONFIG=<path to the hub's kubeconfig>   # or: cp clusters.example.yaml clusters.local.yaml, fill it in, make login
bash hack/quay-env.sh        # once per machine: copies the quay.io/rhoai login into the git-ignored .env
make hub                     # Argo CD builds the hub from this repository's main branch
# commit the hubSiteDigest that bootstrap/50-grid-hub-info.sh prints (a new hub has a new grid CA)
make spokes console          # pull secret, portal callbacks, the console's secrets
```

Then sign in to the provider console (Route `ai-grid-provider-console` in namespace `ai-grid`), open
**Clusters**, and choose **Add to AI Grid** on `local-cluster` (role `combined`). ACM installs OpenShift
AI, MaaS and the grid on it; when the console shows **Provisioned**, run `make verify`.

To build from a fork or branch, set `GIT_REPO` and `GIT_REF` before `make hub`. Nothing secret is stored
in this repository.

## Credits

The `apps/*` layout and several apps follow, and may copy from,
[kahowell/ai-grid-tenant](https://github.com/kahowell/ai-grid-tenant) by Kevin Howell, used with his
permission (2026-10-19). Files copied from it say so at the top.

The Submariner and Limitador Redis setup follows Pierangelo Di Pilato's work in that repository, and
the replicated MaaS database follows Kevin Howell's.

The MaaS Portal sign-in's Authorino rules and route header handling
(`apps/ai-grid-policies/manifests/templates/tenant-portal.yaml`), and the tenant realms' brokering shape
(`apps/keycloak/manifests/realm-*.yaml`: organizations routed by domain to their own identity
providers), are adapted from
[lphiri/maas-portal-integration-poc](https://github.com/lphiri/maas-portal-integration-poc) by Lindani
Phiri, under the MIT License (Copyright (c) 2026 lphiri); its license text is in
[`third-party/maas-portal-integration-poc.LICENSE`](third-party/maas-portal-integration-poc.LICENSE).

Thanos stores metrics in [S4](https://github.com/rh-aiservices-bu/s4) (Apache-2.0), set up after
[rh-aiservices-bu/fraud-detection](https://github.com/rh-aiservices-bu/fraud-detection)'s
`setup/setup-s3.yaml` (Apache-2.0).
