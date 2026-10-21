#!/usr/bin/env bash
# Hub Secrets that can't live in git. rhoai-quay-pull: the deployer's quay login for Policy
# rhoai-pull-secret (D4). The login goes through a pipe in a subshell, never argv; never printed.
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
until kc $HOST get namespace ai-grid-policies >/dev/null 2>&1; do log "waiting for Argo CD app ai-grid-policies"; sleep 10; done
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE: run hack/quay-env.sh"
(
  set -a; source "$ENV_FILE"; set +a
  [[ -n "${QUAY_USER:-}" && -n "${QUAY_TOKEN:-}" ]] || die "QUAY_USER or QUAY_TOKEN empty in $ENV_FILE"
  printf '%s:%s' "$QUAY_USER" "$QUAY_TOKEN" | base64 | tr -d '\n' \
    | kc $HOST create secret generic rhoai-quay-pull -n ai-grid-policies --from-file=auth=/dev/stdin \
        --dry-run=client -o yaml | kc $HOST apply -f - >/dev/null
)
