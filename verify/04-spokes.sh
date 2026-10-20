#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
h=$HOST
uat "app ai-grid-spokes"     "Argo CD app not Synced/Healthy: a Helm render error (an unescaped {{ }}) or a sync retry" app ai-grid-spokes
# Synced only: a Policy still in inform is NonCompliant by design, which Argo CD shows as Degraded.
uat "app ai-grid-policies synced" "a Helm render error (an unescaped {{ }}) in apps/ai-grid-policies" \
  bash -c "kc $h get applications.argoproj.io ai-grid-policies -n openshift-gitops -o jsonpath='{.status.sync.status}' | grep -qx Synced"
for a in ai-grid-spokes ai-grid-policies; do
  # ApplicationSet and ACM expressions must sit inside Helm raw strings ({{`...`}}); unescaped, Helm
  # renders them to nothing without an error. Strip the raw strings, then look for any that remain.
  uat "$a keeps ACM/AppSet templates" "an ApplicationSet or ACM {{ ... }} outside a Helm raw string ({{\`...\`}}) in apps/$a" \
    bash -c "! perl -0777 -ne 's/\\{\\{\\x60.*?\\x60\\}\\}//gs; print \"\$ARGV\\n\" if /\\{\\{-?\\s*(\\.name|\\.server|\\.metadata|index |hub|fromSecret|fromConfigMap|lookup|randAlphaNum|\\.ManagedClusterName)/' apps/$a/manifests/templates/*.yaml | grep ."

done
# Secrets never ride on argv, where ps shows them: no curl argument built from a token or password.
no_argv_secrets() { ! grep -n -E -- "-H \"Authorization: Bearer \\\$|-H 'Authorization: Bearer \\\$|password=\"\\\$" "$@"; }
export -f no_argv_secrets
uat "no secrets on argv" "a script passes a token or password as a curl argument: pipe it (--data-urlencode password@-) or use -H @<(printf ...)" \
  no_argv_secrets bootstrap/*.sh verify/*.sh hack/*.sh
for s in $SPOKES; do
  r=$(role_of $s)
  uat "$s labelled $r"        "add it from the console (Clusters, Add to AI Grid), or the dev shortcut bootstrap/40-spoke.sh" \
    bash -c "kc $h get managedcluster $s -o json | jq -e '.metadata.labels[\"ai-grid/enabled\"]==\"true\" and .metadata.labels[\"ai-grid/role\"]==\"$r\"'"
  uat "$s placed"             "Placement ai-grid-spokes: no ManagedClusterSetBinding 'default' in openshift-gitops, or the cluster isn't in set default" \
    bash -c "kc $h get placementdecisions -n openshift-gitops -l cluster.open-cluster-management.io/placement=ai-grid-spokes -o json | jq -e --arg s $s '[.items[].status.decisions[]?.clusterName] | index(\$s)'"
  uat "$s argo cluster role"  "GitOpsCluster didn't create the cluster Secret, or didn't copy the ai-grid/role label" \
    bash -c "kc $h get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster=true,apps.open-cluster-management.io/cluster-name=$s -o json | jq -e '.items[0].metadata.labels[\"ai-grid/role\"]==\"$r\"'"
  if [[ $PULL_SECRET_MODE == policy ]]; then
    uat "$s pull secret policy" "template error or still inform: kc host get policy ai-grid-policies.rhoai-pull-secret -n $s -o yaml (status.details); fallback: Step 9" pol $s rhoai-pull-secret
  fi
  uat "$s nightly prereqs"    "waits on rhoai-pull-secret being Compliant (Policy dependency)" pol $s rhoai-nightly-prereqs
  uat "$s catalog READY"      "the node can't pull quay.io/rhoai: check the pull secret on the node (verify/01-clusters.sh)" \
    bash -c "kc $s get catalogsource rhoai-catalog-dev -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' | grep -qx READY"
  uat "$s platform app"       "Application platform-$s: a chart value error shows under .status.conditions; a missing CRD is retried" app platform-$s
  uat "$s DSC Ready"          "kc $s get datasciencecluster default-dsc -o yaml: the not-Ready component names the cause" \
    bash -c "kc $s get datasciencecluster default-dsc -o jsonpath='{.status.phase}' | grep -qx Ready"
  if [[ $r != inference ]]; then
    uat "$s maas-db policy"   "CNPG Secret maas-db-app missing on the hub (Task 2), or the hub template didn't resolve" \
      bash -c "kc $h get policy maas-db.maas-db -n $s -o jsonpath='{.status.compliant}' | grep -qx Compliant"
    uat "$s tenant-oidc policy" "hub ConfigMap ai-grid-hub-info missing (Task 3), or AITenant not created yet" pol $s tenant-oidc
    uat "$s tenant-portal policy" "still inform, ConfigMap ai-grid-hub-info lacks tenantIssuer or tenantClientId (bootstrap/35-keycloak.sh), or a template error: kc host get policy ai-grid-policies.tenant-portal -n $s -o yaml" pol $s tenant-portal
    uat "$s maas-api ready"   "maas-db-config not on the spoke, or the hub database unreachable from it (kc $s logs deploy/maas-api -n redhat-ai-gateway-infra)" \
      kc $s rollout status deploy/maas-api -n redhat-ai-gateway-infra --timeout=5s
    maas=$(maas_url $s)
    uat "$s MaaS health 200"  "maas-default-gateway not Programmed, or its listener hostname differs: kc $s get gateway -n openshift-ingress" \
      bash -c "curl -sk -o /dev/null -w '%{http_code}' $maas/maas-api/health | grep -qx 200"
  else
    uat "$s has no MaaS"      "inference values enabled aigateway" bash -c "! kc $s get deploy maas-api -n redhat-ai-gateway-infra"
  fi
done
for s in $MODEL_SITES; do
  uat "$s models app"    "spokes/clusters/$s/models missing, or the ApplicationSet didn't select $s" app models-$s
  uat "$s model Ready"   "image pull or memory: kc $s describe pod -n aigrid-models" \
    bash -c "kc $s get llminferenceservice $MODEL_NAME -n aigrid-models -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
  uat "$s model answers" "vLLM still loading, or the workload Service name differs: kc $s get svc -n aigrid-models" \
    bash -c "kc $s run probe-\$RANDOM -n aigrid-models --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal:latest --quiet -- \
      curl -sk https://${MODEL_NAME}-kserve-workload-svc.aigrid-models.svc:8000/aigrid-models/${MODEL_NAME}/v1/models | grep -q opt-125m"
done
for s in $SPOKES; do
  [[ $(role_of $s) == inference ]] && continue
  uat "$s tenant app"     "spokes/tenant render error, or a MaaS CRD missing (DSC not Ready)" app tenant-$s
  uat "$s MaaSModelRef Ready" "ExternalProvider can't reach grid-gateway.$GRID_NS.svc:443, or no subscription and auth policy pair" \
    bash -c "kc $s get maasmodelref $MODEL_NAME -n models-as-a-service -o jsonpath='{.status.phase}' | grep -qx Ready"
done
summary
