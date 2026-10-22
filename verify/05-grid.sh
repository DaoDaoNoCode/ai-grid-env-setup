#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
h=$HOST
uat "app grid-enrollment"    "Argo CD app not Synced/Healthy: the OCI chart pull (praxis-charts), or the bootstrap hook" app grid-enrollment
uat "enrollment pod ready"   "image pull from ghcr.io, or the bootstrap Job failed: kc host get jobs -n grid-enrollment, then its log" \
  kc $h rollout status deploy/grid-enrollment -n grid-enrollment --timeout=5s
uat "grid CA issued"         "the CA bootstrap Job failed: kc host get jobs -n grid-enrollment, then its log" \
  bash -c "kc $h get secret grid-ca-bundle -n grid-enrollment && kc $h get secret enrollment-serving-tls -n grid-enrollment -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer | grep -q grid-ca"
uat "hub site identity"      "hubSite.name unset, or namespace grid created after the release" \
  kc $h get secret grid-site-identity -n grid
uat "hub swim key"           "hubSite.swimKeySecretName empty" kc $h get secret grid-swim-key -n grid
uat "enrollment db ready"    "PVC not bound (gp3-csi) or the DB cert missing" \
  bash -c "kc $h get pods -n grid-enrollment -l app.kubernetes.io/component=db -o jsonpath='{.items[0].status.containerStatuses[0].ready}' | grep -qx true"
uat "pinned digest is this hub's" "apps/ai-grid-spokes/manifests/values.yaml hubSiteDigest is from another build (D8): copy ai-grid-hub-info's hubSiteDigest there and commit" \
  bash -c "[ \"\$(yq '.hubSiteDigest' apps/ai-grid-spokes/manifests/values.yaml)\" = \"\$(kc $h get configmap ai-grid-hub-info -n ai-grid-policies -o jsonpath='{.data.hubSiteDigest}')\" ]"
uat "hub info for spokes"    "bootstrap/50-grid-hub-info.sh not run" \
  bash -c "kc $h get configmap ai-grid-hub-info -n ai-grid-policies -o json | jq -e '.data.hubSiteDigest | length == 64'"
for s in $SPOKES; do
  r=$(site_role $s)
  uat "$s grid operator app" "chart pull from ghcr.io (repository praxis-charts) or a values error" app grid-operator-$s
  uat "$s operator ready"    "no grid-site-identity in $GRID_NS (enrollment, Task 4; invite, Task 11)" \
    kc $s rollout status deploy/grid-operator -n $GRID_NS --timeout=5s
  # Peer sites must be Active. A site's own record stays Discovered in a one-site grid: v0.2.0 moves
  # a site to Active once gossip gives it an egress address, which needs a peer (Task 11).
  uat "$s peer sites Active" "gossip not converged, or the GridSite list failed: kc $s get gridsites" \
    bash -c "l=\$(kc $s get gridsites -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{\"\\n\"}{end}') || exit 1; grep -q '^$s ' <<<\"\$l\" || exit 1; ! grep -v '^$s ' <<<\"\$l\" | grep -v ' Active\$' | grep -q ."
  uat "$s ai-grid-ready"     "DSC not Ready or the grid operator not running on $s (D3)" pol $s ai-grid-ready
  # Inference sites serve other clusters' consumers through their exported provider; every other
  # site's consumer calls each one in providerGlobalIPs at its Globalnet address.
  if [[ $r == inference ]]; then
    uat "$s provider, no consumer" "the consumer ApplicationSet selects role inference, or the provider's doesn't" \
      bash -c "app grid-provider-$s && ! kc $h get applications.argoproj.io grid-consumer-$s -n openshift-gitops"
    ip=$(yq ".providerGlobalIPs[\"$s\"] // \"\"" apps/ai-grid-spokes/manifests/values.yaml)
    uat "$s provider address committed" "bash bootstrap/50-grid-hub-info.sh prints providerGlobalIPs.$s: commit it in apps/ai-grid-spokes/manifests/values.yaml" \
      bash -c "[ -n '$ip' ] && [ \"\$(kc $s get globalingressip grid-provider-fixed -n $GRID_NS -o jsonpath='{.status.allocatedIP}')\" = '$ip' ]"
  fi
  if [[ $r == ingress ]]; then
    uat "$s has a remote inference site" "an ingress spoke has no provider of its own: add an inference site and its providerGlobalIPs entry" \
      bash -c "[ \"\$(yq '.providerGlobalIPs | length' apps/ai-grid-spokes/manifests/values.yaml)\" -gt 0 ]"
  fi
  if [[ $r != inference ]]; then
    for t in $(yq '.providerGlobalIPs | keys | .[]' apps/ai-grid-spokes/manifests/values.yaml); do
      [[ $t == "$s" ]] && continue
      ip=$(yq ".providerGlobalIPs[\"$t\"]" apps/ai-grid-spokes/manifests/values.yaml)
      uat "$s consumer calls $t" "Argo CD app grid-consumer-$s not synced, or providerGlobalIPs.$t missing" \
        bash -c "kc $s get configmap grid-gateway-config -n $GRID_NS -o jsonpath='{.data.praxis\.yaml}' | grep -qF '\"$ip:8443\"'"
    done
  fi
done
# The inference split's lists follow the spokes' roles: each providerGlobalIPs key is an inference spoke,
# and consumerSites (whose digests inference providers pin) is exactly the ingress and combined spokes.
v=apps/ai-grid-spokes/manifests/values.yaml
if [[ $(yq '.providerGlobalIPs | length' $v) -gt 0 ]]; then
  for t in $(yq '.providerGlobalIPs | keys | .[]' $v); do
    uat "providerGlobalIPs.$t is an inference spoke" "$t isn't in SPOKES with role inference: only inference sites export their provider" \
      test "$(site_role $t)" = inference
  done
  want=$(for s in $SPOKES; do [[ $(site_role $s) != inference ]] && echo $s; done | sort | xargs)
  uat "consumerSites are the ingress and combined spokes" "set consumerSites in $v to: $want (inference providers pin exactly these sites)" \
    test "$(yq '.consumerSites[]' $v | sort | xargs)" = "$want"
fi
# Remote sites enroll at enrollHost; its serving certificate must name it. The bootstrap that
# issues it is a hook, and Argo CD skips hooks when nothing else changed: after changing
# serving.extraDnsNames, sync grid-enrollment by hand (runbook).
if [[ -n ${SITES// /} ]]; then
  eh=$(yq '.enrollHost' apps/ai-grid-spokes/manifests/values.yaml); eh=${eh%%:*}
  uat "enrollment certificate names $eh" "the serving certificate predates serving.extraDnsNames: sync Argo CD app grid-enrollment by hand, then restart deploy/grid-enrollment" \
    bash -c "kc $h get secret enrollment-serving-tls -n grid-enrollment -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName | grep -q 'DNS:$eh\(,\|\$\)'"
fi
# Remote sites: an invite token, delivered with the CA bundle and gossip key by ACM Policy
# grid-invite-<site> (Argo CD calls it Healthy while it waits; this is its real state).
for s in $SITES; do
  uat "$s invite minted" "the invite Job (PostSync) hasn't run: kc host get jobs -n grid-enrollment; or invites.$s is missing from apps/grid-enrollment" \
    kc $h get secret grid-invite-$s -n grid-enrollment
  uat "$s invite delivered" "Policy grid-invite-$s NonCompliant: kc host get policy grid-enrollment.grid-invite-$s -n $s -o yaml" \
    bash -c "kc $h get policy grid-enrollment.grid-invite-$s -n $s -o jsonpath='{.status.compliant}' | grep -qx Compliant"
  # A missing or mistyped siteDigests key falls back to the zeros pin: the provider refuses everyone.
  uat "$s digest pinned" "siteDigests.$s in apps/ai-grid-spokes/manifests/values.yaml is missing, not 64 hex, or from another build: bash bootstrap/50-grid-hub-info.sh prints it" \
    bash -c "p=\$(yq '.siteDigests[\"$s\"]' apps/ai-grid-spokes/manifests/values.yaml); grep -Eqx '[0-9a-f]{64}' <<<\"\$p\" && [ \"\$p\" = \"\$(kc $s get gridnetworks -n $GRID_NS -o jsonpath='{.items[*].status.identity.fingerprint}')\" ]"
done
summary
