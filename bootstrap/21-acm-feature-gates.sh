#!/usr/bin/env bash
# The ClusterManager belongs to the ACM operator, so a script (not Argo CD) turns on the
# ManifestWorkReplicaSet gate once ACM is running. Safe to rerun.
source "$(dirname "$0")/lib.sh"
kc $HOST wait multiclusterhub/multiclusterhub -n open-cluster-management --for=jsonpath='{.status.phase}'=Running --timeout=30m
# Add the gate to whatever gates are already set; a merge patch would replace the whole list.
gates=$(kc $HOST get clustermanager cluster-manager -o json | jq -c '[.spec.workConfiguration.featureGates // [] | .[]
  | select(.feature != "ManifestWorkReplicaSet")] + [{"feature":"ManifestWorkReplicaSet","mode":"Enable"}]')
kc $HOST patch clustermanager cluster-manager --type merge -p "{\"spec\":{\"workConfiguration\":{\"featureGates\":$gates}}}"
