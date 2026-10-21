#!/usr/bin/env bash
# Records the hub site's certificate digest in ConfigMap ai-grid-hub-info (Task 11 adds enrollment's
# host once it has a Route). The grid gateways pin this digest from apps/ai-grid-spokes/manifests/
# values.yaml (D8), so after a rebuild copy it there and commit. Likewise each remote site's own
# digest and an inference site's Globalnet address. Rerun after a rebuild or after adding a site.
source "$(dirname "$0")/lib.sh"
kc $HOST wait --for=create secret/grid-site-identity -n grid --timeout=15m
digest=$(kc $HOST get secret grid-site-identity -n grid -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1)
kc $HOST patch configmap ai-grid-hub-info -n ai-grid-policies --type merge \
  -p "{\"data\":{\"hubSiteDigest\":\"$digest\"}}"
pinned=$(yq '.hubSiteDigest' "$(dirname "$0")/../apps/ai-grid-spokes/manifests/values.yaml")
[[ $pinned == "$digest" ]] || log "commit this digest: set hubSiteDigest: \"$digest\" in apps/ai-grid-spokes/manifests/values.yaml (D8)"
# Each remote site's own digest, once it has enrolled: its provider gateway pins it (siteDigests).
# stderr apart from the digest, so a kubectl warning can't end up in the printed pin.
err=$(mktemp); trap 'rm -f "$err"' EXIT
for s in $SITES; do
  # No GridNetwork kind, object or fingerprint yet means not enrolled; any other error stops.
  if ! fp=$(kc $s get gridnetworks -n "$GRID_NS" -o jsonpath='{.items[*].status.identity.fingerprint}' 2>"$err"); then
    grep -q "doesn't have a resource type" "$err" || die "can't read $s's GridNetwork: $(cat "$err")"
    fp=
  fi
  [[ -n $fp ]] || { log "$s hasn't enrolled yet: rerun after adding it to AI Grid"; continue; }
  pinned=$(yq ".siteDigests[\"$s\"]" "$(dirname "$0")/../apps/ai-grid-spokes/manifests/values.yaml")
  [[ $pinned == "$fp" ]] || log "commit this digest: set siteDigests.$s: \"$fp\" in apps/ai-grid-spokes/manifests/values.yaml"
done
# Each inference site's Globalnet address, which other sites' consumers dial (providerGlobalIPs).
for s in $SITES; do
  [[ $(site_role "$s") == inference ]] || continue
  ip=$(kc $s get globalingressip grid-provider-fixed -n "$GRID_NS" -o jsonpath='{.status.allocatedIP}' 2>/dev/null || true)
  [[ -n $ip ]] || { log "$s has no Globalnet address for its provider yet: rerun once grid-provider-export-$s is Healthy"; continue; }
  pinned=$(yq ".providerGlobalIPs[\"$s\"]" "$(dirname "$0")/../apps/ai-grid-spokes/manifests/values.yaml")
  [[ $pinned == "$ip" ]] || log "commit this address: set providerGlobalIPs.$s: \"$ip\" in apps/ai-grid-spokes/manifests/values.yaml"
done
