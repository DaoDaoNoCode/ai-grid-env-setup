#!/usr/bin/env bash
# The only imperative hub step: install OpenShift GitOps and point it at apps/*. Everything else on
# the hub is an Argo CD app from git (apps/*/application.yaml). Safe to rerun.
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
kc $HOST apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata: { name: openshift-gitops-operator }
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: { name: openshift-gitops-operator, namespace: openshift-gitops-operator }
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: { name: openshift-gitops-operator, namespace: openshift-gitops-operator }
spec: { channel: latest, name: openshift-gitops-operator, source: redhat-operators, sourceNamespace: openshift-marketplace }
YAML
until kc $HOST get argocd openshift-gitops -n openshift-gitops >/dev/null 2>&1; do sleep 10; done
kc $HOST apply -f bootstrap/gitops-admin.yaml
# Argo CD admin for the person running this: Argo CD maps OpenShift group cluster-admins to
# role:admin, and a demo.redhat.com order has no such group. Who else gets access is per
# environment, so it stays out of git (docs/runbook.md, "Access").
me=$(kc $HOST whoami)
kc $HOST get group cluster-admins >/dev/null 2>&1 || kc $HOST adm groups new cluster-admins
kc $HOST adm groups add-users cluster-admins "$me" >/dev/null
GIT_REPO=$GIT_REPO GIT_REF=$GIT_REF envsubst '${GIT_REPO} ${GIT_REF}' < bootstrap/applicationset.yaml | kc $HOST apply -f -
log "Argo CD now builds the hub from $GIT_REPO@$GIT_REF apps/*; watch: kc host get applications -n openshift-gitops"
