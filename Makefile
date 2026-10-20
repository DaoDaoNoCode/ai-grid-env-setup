SHELL := /bin/bash
.PHONY: hub spokes all verify console teardown
# Run hack/quay-env.sh once first. Every script is safe to rerun.
hub:
	bash bootstrap/00-gitops.sh
	bash bootstrap/21-acm-feature-gates.sh
	bash bootstrap/25-hub-secrets.sh
	bash bootstrap/35-keycloak.sh
	bash bootstrap/50-grid-hub-info.sh
# On a new hub, commit the hubSiteDigest that 50-grid-hub-info.sh prints (D8) before this.
spokes:
	bash bootstrap/10-pull-secret.sh
	bash bootstrap/40-spoke.sh
	bash bootstrap/36-portal-clients.sh
all: hub spokes
verify:
	@rc=0; for f in verify/[0-9]*.sh; do echo "== $$f"; bash $$f || rc=1; done; exit $$rc
# The provider console (Task 9): Argo CD app console builds and deploys it; this adds its secrets.
console:
	bash bootstrap/60-console.sh
teardown:
	bash bootstrap/99-teardown.sh
