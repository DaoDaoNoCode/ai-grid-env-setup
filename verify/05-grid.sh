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
uat "hub info for spokes"    "bootstrap/50-grid-hub-info.sh not run" \
  bash -c "kc $h get configmap ai-grid-hub-info -n ai-grid-policies -o json | jq -e '.data.hubSiteDigest | length == 64'"
summary
