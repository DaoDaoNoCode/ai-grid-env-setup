#!/usr/bin/env bash
# Copy the deployer's quay.io login (from `podman login quay.io`) into .env as QUAY_USER and
# QUAY_TOKEN. Prints the user name only, never the token.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./env.sh
authfile="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
[[ -f "$authfile" ]] || { echo "no podman login found; run: podman login quay.io" >&2; exit 1; }
auth=$(jq -r '.auths["quay.io/rhoai"].auth // .auths["quay.io"].auth // empty' "$authfile")
[[ -n "$auth" ]] || { echo "$authfile has no stored quay.io password (a credential helper holds it); run: podman login --authfile $authfile quay.io" >&2; exit 1; }
pair=$(base64 -d <<<"$auth"); unset auth
user=${pair%%:*} token=${pair#*:}; unset pair
[[ "$user$token" != *"'"* ]] || { echo "the login contains a single quote; set .env by hand" >&2; exit 1; }
umask 077; tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{ [[ -f "$ENV_FILE" ]] && grep -vE '^(QUAY_USER|QUAY_TOKEN)=' "$ENV_FILE" || true
  printf "QUAY_USER='%s'\nQUAY_TOKEN='%s'\n" "$user" "$token"; } >"$tmp"
unset token
mv "$tmp" "$ENV_FILE" && chmod 600 "$ENV_FILE"
echo "wrote QUAY_USER=$user and QUAY_TOKEN to $ENV_FILE"
