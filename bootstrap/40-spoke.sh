#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
for s in $SPOKES; do
  r=$(role_of $s); [[ -n $r ]] || die "no role for $s in SPOKE_ROLES"
  # local-cluster appears once ACM has imported the hub itself; a remote spoke must be imported first (Task 11).
  for _ in $(seq 1 60); do kc $HOST get managedcluster $s >/dev/null 2>&1 && break; sleep 10; done
  kc $HOST get managedcluster $s >/dev/null 2>&1 || die "$s isn't a ManagedCluster on the hub: import it first (Task 11)"
  kc $HOST label managedcluster $s --overwrite \
    "$LABEL_ENABLED=true" "$LABEL_ROLE=$r" "$LABEL_LOCATION=$(location_of $s)"
done
