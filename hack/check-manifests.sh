#!/usr/bin/env bash
# Checks every directory Argo CD deploys from, without a cluster, and fails on one it can't check:
#   bash hack/check-manifests.sh <gitRepo> <gitRef>
# - a Helm chart is templated with the root ApplicationSet's gitRepo and gitRef (its subdirectories are
#   the chart's own);
# - a kustomization is built;
# - an app whose chart lives in another repository (spec.chart in its application.yaml, the console)
#   is templated at its pinned commit with the app's values.yaml, and the console's three pins of
#   that commit (the chart, the ghcr.io image tags, the BuildConfig refs) must agree;
# - a Kustomize Component renders only through the kustomization that names it, so its files are parsed;
# - plain YAML is parsed, and each document needs apiVersion and kind, except Helm value files (a
#   directory named values);
# - any other file in a plain directory fails: Argo CD would deploy it, or nothing here checks it.
set -euo pipefail
repo=${1:?usage: hack/check-manifests.sh <gitRepo> <gitRef>} ref=${2:?usage: hack/check-manifests.sh <gitRepo> <gitRef>}
cd "$(dirname "$0")/.."
bad=0
fail() { echo "FAIL      $*"; bad=1; }
parse() { yq ea '.' "$@" >/dev/null; }

charts=$(find apps/*/manifests hub spokes -name Chart.yaml -exec dirname {} \;)
for d in $(find apps/*/manifests hub spokes -type d | sort); do
  inside=; for c in $charts; do [[ $d == "$c"/* ]] && inside=1; done
  [[ $inside ]] && continue
  if [[ -f $d/Chart.yaml ]]; then
    if grep -q '^dependencies:' "$d/Chart.yaml"; then helm dependency build "$d" >/dev/null; fi
    helm template ci "$d" --set "gitRepo=$repo,gitRef=$ref" >/dev/null || { fail "$d: helm template"; continue; }
    echo "helm      $d"
  elif [[ -f $d/kustomization.yaml && $(yq '.kind' "$d/kustomization.yaml") == Component ]]; then
    parse "$d"/*.yaml || { fail "$d: YAML"; continue; }
    echo "component $d (parsed)"
  elif [[ -f $d/kustomization.yaml ]]; then
    kubectl kustomize "$d" >/dev/null || { fail "$d: kustomize"; continue; }
    echo "kustomize $d"
  else
    files=$(find "$d" -maxdepth 1 -type f | sort)
    [[ -z $files ]] && continue   # a parent of other targets
    ok=0
    for f in $files; do
      [[ $f == *.yaml ]] || { fail "$f: not a chart, kustomization or .yaml file"; continue; }
      parse "$f" || { fail "$f: YAML"; continue; }
      if [[ $(basename "$d") != values && $(yq ea '[select(. != null) | has("apiVersion") and has("kind")] | all' "$f") != true ]]; then
        fail "$f: a document without apiVersion and kind"; continue
      fi
      ok=$((ok + 1))
    done
    echo "yaml      $d ($ok of $(wc -w <<<"$files" | tr -d ' ') files parsed)"
  fi
done

# An app whose chart lives in another repository (spec.chart in its application.yaml) is templated at
# the pinned commit with the app's values.yaml, as the root ApplicationSet deploys it.
for a in apps/*/application.yaml; do
  [[ $(yq '.spec | has("chart")' "$a") == true ]] || continue
  d=$(dirname "$a") tmp=$(mktemp -d)
  url=$(yq .spec.chart.repoURL "$a") rev=$(yq .spec.chart.targetRevision "$a") path=$(yq .spec.chart.path "$a")
  if git -C "$tmp" init -q && git -C "$tmp" fetch -q --depth 1 "$url" "$rev" && git -C "$tmp" checkout -q FETCH_HEAD &&
    helm template "$(yq .spec.chart.releaseName "$a")" "$tmp/$path" -n "$(yq .spec.destination.namespace "$a")" -f "$d/values.yaml" >/dev/null; then
    echo "chart     $d ($path at $rev, values.yaml)"
  else
    fail "$d: chart $path at $rev with values.yaml"
  fi
  rm -rf "$tmp"
done

# An app sets helmGit or chart, not both: the root ApplicationSet would write source twice.
for a in apps/*/application.yaml; do
  [[ $(yq '(.spec | has("helmGit")) and (.spec | has("chart"))' "$a") == true ]] && fail "$a: spec.helmGit and spec.chart are exclusive"
done

# The console's commit is pinned three times: the chart (application.yaml), the image tags
# (values.yaml, sha-<commit> on ghcr.io) and the in-cluster BuildConfigs (manifests/builds.yaml).
# A partial bump would deploy one commit's chart with another's images; the backend's tag and
# BuildConfig ref must agree the same way.
c=apps/console
chart_rev=$(yq .spec.chart.targetRevision $c/application.yaml)
bc_ref() { yq "select(.kind == \"BuildConfig\" and .spec.source.git.uri == \"$1\") | .spec.source.git.ref" $c/manifests/builds.yaml; }
console_bc=$(bc_ref https://github.com/ai-grid-cloud/ai-grid-provider-console.git)
backend_bc=$(bc_ref https://github.com/ai-grid-cloud/ai-grid-provider-backend.git)
[[ $console_bc == "$chart_rev" ]] || fail "$c: BuildConfig ref $console_bc for the console isn't the chart's $chart_rev"
for i in console:$chart_rev backend:$backend_bc; do
  img=${i%%:*} want=sha-${i#*:}
  [[ $(yq ".images.$img.repository" $c/values.yaml) == ghcr.io/* ]] || continue
  tag=$(yq ".images.$img.tag" $c/values.yaml)
  [[ $tag == "$want" ]] || fail "$c: images.$img.tag $tag isn't $want (the commit the chart or BuildConfig pins)"
done
exit $bad
