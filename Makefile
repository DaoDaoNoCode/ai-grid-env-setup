SHELL := /bin/bash
.PHONY: hub spokes all verify console teardown spoke-gpu spoke-gpu-delete spoke-cpu spoke-cpu-delete spoke-infra spoke-join spoke-commit spoke-uninstall
# Run hack/quay-env.sh once first. Every script is safe to rerun.
hub:
	bash bootstrap/00-gitops.sh
	bash bootstrap/21-acm-feature-gates.sh
	bash bootstrap/25-hub-secrets.sh
	bash bootstrap/35-keycloak.sh
	bash bootstrap/50-grid-hub-info.sh
# On a new hub, commit the hubSiteDigest that 50-grid-hub-info.sh prints (D8) before this.
# Prepares spokes but labels none: the provider adds each cluster from the console (Add to AI Grid).
# Dev shortcut without the console: bash bootstrap/40-spoke.sh
spokes:
	bash bootstrap/10-pull-secret.sh
	bash bootstrap/36-portal-clients.sh
all: hub spokes
verify:
	@rc=0; for f in verify/[0-9]*.sh; do echo "== $$f"; bash $$f || rc=1; done; exit $$rc
# The provider console (Task 9): Argo CD app console builds and deploys it; this adds its secrets.
console:
	bash bootstrap/60-console.sh
teardown:
	bash bootstrap/99-teardown.sh
# Preparing a remote spoke (kubeconfig $KUBEDIR/<SPOKE>); see the runbook's remote-spoke table.
# GPU_INSTANCE_TYPE (g6.xlarge), GPU_REPLICAS, GPU_AZ, CPU_INSTANCE_TYPE, CPU_REPLICAS, DRY_RUN=1 tune them.
need-spoke = @test -n "$(SPOKE)" || { echo "usage: make $@ SPOKE=<name>"; exit 1; }
spoke-gpu:
	$(need-spoke)
	bash hack/spoke-machineset.sh gpu apply $(SPOKE)
spoke-gpu-delete:
	$(need-spoke)
	bash hack/spoke-machineset.sh gpu delete $(SPOKE)
spoke-cpu:
	$(need-spoke)
	bash hack/spoke-machineset.sh cpu apply $(SPOKE)
spoke-cpu-delete:
	$(need-spoke)
	bash hack/spoke-machineset.sh cpu delete $(SPOKE)
# GPU node; add CPU=1 for a CPU worker too. ACM Policies deliver the mirror and monitoring after the Add.
spoke-infra:
	$(need-spoke)
	$(MAKE) spoke-gpu SPOKE=$(SPOKE)
	$(if $(CPU),$(MAKE) spoke-cpu SPOKE=$(SPOKE))
# On the hub: import, invite, models directory, portal callback; then offers to commit and push them.
spoke-join:
	$(need-spoke)
	bash bootstrap/46-spoke-join.sh $(SPOKE)
# Commits and pushes only the spoke's invite and models directory, without asking (for re-runs).
spoke-commit:
	$(need-spoke)
	bash hack/spoke-commit.sh $(SPOKE)
# Deletes OpenShift AI, MaaS and the grid from the spoke (bootstrap/98-uninstall-spoke.sh). Asks for the
# name at a terminal; otherwise CONFIRM=<SPOKE>. Use it instead of Remove in the console, not after.
spoke-uninstall:
	$(need-spoke)
	bash bootstrap/98-uninstall-spoke.sh $(SPOKE)
