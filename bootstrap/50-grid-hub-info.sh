#!/usr/bin/env bash
# Records the hub site's certificate digest in ConfigMap ai-grid-hub-info (Task 11 adds enrollment's
# host once it has a Route). The grid gateways pin this digest from apps/ai-grid-spokes/manifests/
# values.yaml (D8), so after a rebuild copy it there and commit. Rerun after a rebuild.
source "$(dirname "$0")/lib.sh"
kc $HOST wait --for=create secret/grid-site-identity -n grid --timeout=15m
digest=$(kc $HOST get secret grid-site-identity -n grid -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1)
kc $HOST patch configmap ai-grid-hub-info -n ai-grid-policies --type merge \
  -p "{\"data\":{\"hubSiteDigest\":\"$digest\"}}"
pinned=$(yq '.hubSiteDigest' "$(dirname "$0")/../apps/ai-grid-spokes/manifests/values.yaml")
[[ $pinned == "$digest" ]] || log "commit this digest: set hubSiteDigest: \"$digest\" in apps/ai-grid-spokes/manifests/values.yaml (D8)"
