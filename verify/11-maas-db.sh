#!/usr/bin/env bash
# maas-api's database on the hub: three instances, exported for remote ingress spokes, which keep a
# read replica. On one cluster there's no remote spoke, so this checks the hub side and the wiring.
source "$(dirname "$0")/lib.sh"
h=$HOST
uat "maas-db three instances" "CloudNativePG hasn't added the standbys: kc host get cluster.postgresql.cnpg.io maas-db -n maas-db -o yaml" \
  bash -c "kc $h get cluster.postgresql.cnpg.io maas-db -n maas-db -o json | jq -e '.status.readyInstances == 3 and .spec.instances == 3'"
uat "maas-db exported"        "ServiceExport maas-db-rw not Valid: Submariner's Lighthouse (verify/09)" \
  bash -c "kc $h get serviceexport maas-db-rw -n maas-db -o jsonpath='{.status.conditions[?(@.type==\"Valid\")].status}' | grep -qx True"
uat "maas-db read endpoint"   "Service maas-read-ro missing (apps/maas-db)" \
  bash -c "kc $h get svc maas-read-ro -n maas-db -o jsonpath='{.spec.externalName}' | grep -qx maas-db-ro.maas-db.svc.cluster.local"
# Exported clusterset-wide, so the namespace admits 5432 only from maas-api, CloudNativePG itself,
# and other clusters' Globalnet addresses. Probe from a namespace with no business there.
uat "maas-db refuses other namespaces" "NetworkPolicy maas-db-ingress missing or too wide (apps/maas-db)" \
  bash -c "! kc $h exec -n openshift-gitops deploy/openshift-gitops-repo-server -- timeout 4 bash -c '</dev/tcp/maas-db-rw.maas-db.svc/5432' 2>/dev/null"
uat "replica placement skips the hub" "Placement ai-grid-ingress-remote picked local-cluster" \
  bash -c "! kc $h get placementdecisions -n maas-db -l cluster.open-cluster-management.io/placement=ai-grid-ingress-remote -o json | jq -e '[.items[].status.decisions[]?.clusterName] | index(\"local-cluster\")'"
for s in $SPOKES; do
  [[ $(role_of $s) == inference ]] && continue
  # The host only: the URL also holds the password, which must never be printed.
  want=maas-db-rw.maas-db.svc.clusterset.local; [[ $s == local-cluster ]] && want=maas-db-rw.maas-db.svc
  uat "$s maas-api database host" "Policy maas-db gave $s the wrong host (want $want)" \
    bash -c "kc $s get secret maas-db-config -n redhat-ai-gateway-infra -o jsonpath='{.data.DB_CONNECTION_URL}' | base64 -d | sed -E 's|^[^@]*@([^:/]*).*|\1|' | grep -qx $want"
  # SCRAM bound to the TLS channel: an impersonating server can't complete the login, and SCRAM
  # never sends the password. Parameters only; the URL is never printed.
  uat "$s maas-api database login pinned" "Policy maas-db's URL lacks require_auth=scram-sha-256 and channel_binding=require" \
    bash -c "kc $s get secret maas-db-config -n redhat-ai-gateway-infra -o jsonpath='{.data.DB_CONNECTION_URL}' | base64 -d | sed 's/^[^?]*?//' | tr '&' '\\n' | sort | tr '\\n' ' ' | grep -q 'channel_binding=require require_auth=scram-sha-256 sslmode=require'"
  uat "$s maas-api reaches its database" "maas-api can't log in (its pgx too old for the URL's parameters, or no SCRAM-SHA-256-PLUS): kc $s logs deploy/maas-api -n redhat-ai-gateway-infra" \
    bash -c "kc $s rollout status deploy/maas-api -n redhat-ai-gateway-infra --timeout=5s && ! kc $s logs deploy/maas-api -n redhat-ai-gateway-infra --since=10m | grep -i -E 'failed to connect|database.*error|sasl|channel binding'"
  if [[ $s != local-cluster ]]; then
    uat "$s replica streaming"  "kc $s get cluster.postgresql.cnpg.io maas-read -n maas-db -o yaml: replication certs (Policy maas-db-replication) or the clusterset route" \
      bash -c "kc $s get cluster.postgresql.cnpg.io maas-read -n maas-db -o jsonpath='{.status.phase}' | grep -qx 'Cluster in healthy state'"
  fi
done
summary
