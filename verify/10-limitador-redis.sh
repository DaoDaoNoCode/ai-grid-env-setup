#!/usr/bin/env bash
# Limitador keeps MaaS's rate-limit counters in Redis (with Sentinel), exported through Submariner so
# more than one MaaS gateway can share them. Run after 06-tenant-e2e, whose calls make counters.
source "$(dirname "$0")/lib.sh"
for s in $SPOKES; do
  [[ $(role_of $s) == inference ]] && continue
  uat "$s limitador-redis app" "ApplicationSet ai-grid-limitador-redis: no Application for $s, or a sync error" app limitador-redis-$s
  uat "$s redis operator"      "the community redis-operator didn't install: kc $s get csv -n limitador-redis" \
    bash -c "kc $s get csv -n limitador-redis -o json | jq -e '[.items[] | select(.metadata.name | startswith(\"redis-operator\")) | .status.phase] | index(\"Succeeded\")'"
  uat "$s redis replicas ready" "kc $s get pods -n limitador-redis: image pull (registry.redhat.io) or PVCs" \
    bash -c "[ \$(kc $s get statefulset limitador-redis -n limitador-redis -o jsonpath='{.status.readyReplicas}') = 3 ]"
  uat "$s redis master answers" "no pod labelled redis-role=master: Sentinel hasn't elected one" \
    bash -c "kc $s get endpoints limitador-redis-master -n limitador-redis -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q ."
  uat "$s limitador uses redis" "Limitador's spec.storage isn't redis (the Kuadrant operator reset it?) or its pod didn't roll" \
    bash -c "kc $s get limitador limitador -n kuadrant-system -o jsonpath='{.spec.storage.redis.configSecretRef.name}' | grep -qx limitador-redis-url && kc $s get deploy limitador-limitador -n kuadrant-system -o json | jq -e '[.spec.template.spec.containers[0].command[]?, .spec.template.spec.containers[0].args[]?] | map(select(test(\"redis\"))) | length > 0' && kc $s rollout status deploy/limitador-limitador -n kuadrant-system --timeout=5s"
  uat "$s counters in redis"   "Limitador still counts in memory, or no rate-limited call ran (06-tenant-e2e)" \
    bash -c "m=\$(kc $s get pods -n limitador-redis -l redis-role=master -o name | head -1); [ \$(kc $s exec -n limitador-redis \$m -c limitador-redis -- sh -c 'REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli dbsize') -gt 0 ]"
  uat "$s redis needs a password" "Redis answers without auth: RedisReplication's redisSecret (Secret limitador-redis-auth, Job limitador-redis-auth)" \
    bash -c "m=\$(kc $s get pods -n limitador-redis -l redis-role=master -o name | head -1); kc $s exec -n limitador-redis \$m -c limitador-redis -- redis-cli ping 2>&1 | grep -q NOAUTH"
  uat "$s redis password kept, no copies" "limitador-redis-auth or limitador-redis-url lost its data, or carries a last-applied copy" \
    bash -c "kc $s get secret limitador-redis-auth -n limitador-redis -o json | jq -e '(.data.password | length > 0) and (.metadata.annotations[\"kubectl.kubernetes.io/last-applied-configuration\"] == null)' && kc $s get secret limitador-redis-url -n kuadrant-system -o json | jq -e '(.data.URL | length > 0) and (.metadata.annotations[\"kubectl.kubernetes.io/last-applied-configuration\"] == null)'"
  uat "$s redis exported"      "ServiceExport limitador-redis-master not Valid: Submariner's Lighthouse (verify/09)" \
    bash -c "kc $s get serviceexport limitador-redis-master -n limitador-redis -o jsonpath='{.status.conditions[?(@.type==\"Valid\")].status}' | grep -qx True"
done
summary
