# ai-grid-env-setup

Builds a rebuildable AI Grid demo environment: an ACM hub (ACM, Argo CD, Keycloak, grid enrollment,
the provider console) that provisions labelled spoke clusters with OpenShift AI, MaaS, and the grid
from the [odh-gitops](https://github.com/opendatahub-io/odh-gitops) chart.

- `env.sh`: every setting and pin, sourced by all scripts.
- `bootstrap/`: idempotent scripts for the steps that carry secrets or run before Argo CD.
- `verify/`: user-level checks; `make verify` runs them all.
- `docs/runbook.md`: cluster facts, access, and the UAT log.
- Sample model (fixture): `spokes/models/opt-125m` and `spokes/tenant/` (opt-125m, its MaaS model and the org1 subscription) exist only so `verify/06-tenant-e2e.sh` has a model to call; they're deleted once the provider console deploys models and creates subscriptions.

Set `HOST_KUBECONFIG` to the hub's kubeconfig file in your shell before running anything.
Nothing secret is stored in this repository.

## Credits

The `apps/*` layout and several apps follow, and may copy from,
[kahowell/ai-grid-tenant](https://github.com/kahowell/ai-grid-tenant) by Kevin Howell, used with his
permission (2026-10-19). Files copied from it say so at the top.

The Submariner and Limitador Redis setup follows Pierangelo Di Pilato's work in that repository, and
the replicated MaaS database follows Kevin Howell's.

The MaaS Portal sign-in's Authorino rules and route header handling
(`apps/ai-grid-policies/manifests/templates/tenant-portal.yaml`) are adapted from
[lphiri/maas-portal-integration-poc](https://github.com/lphiri/maas-portal-integration-poc) by Lindani
Phiri, under the MIT License (Copyright (c) 2026 lphiri); its license text is in
[`third-party/maas-portal-integration-poc.LICENSE`](third-party/maas-portal-integration-poc.LICENSE).

Thanos stores metrics in [S4](https://github.com/rh-aiservices-bu/s4) (Apache-2.0), set up after
[rh-aiservices-bu/fraud-detection](https://github.com/rh-aiservices-bu/fraud-detection)'s
`setup/setup-s3.yaml` (Apache-2.0).
