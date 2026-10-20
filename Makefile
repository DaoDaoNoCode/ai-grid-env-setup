SHELL := /bin/bash
.PHONY: verify
# Run hack/quay-env.sh once first. Every script is safe to rerun.
verify:
	@rc=0; for f in verify/[0-9]*.sh; do echo "== $$f"; bash $$f || rc=1; done; exit $$rc
