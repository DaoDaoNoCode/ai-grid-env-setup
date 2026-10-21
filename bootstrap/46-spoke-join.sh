#!/usr/bin/env bash
# Runs on the hub: everything a remote spoke needs before the console's Add (Task 11, steps 1 to 3):
#   bash bootstrap/46-spoke-join.sh <spoke>      (kubeconfig $KUBEDIR/<spoke>)
# Imports it into ACM, makes sure its invite and models directory exist in the working tree, and adds
# its portal callback to maas-cli. The invite lives in git: at a terminal it shows the change and asks
# before committing and pushing those two paths (hack/spoke-commit.sh); otherwise it prints the command.
# 36-portal-clients.sh sets the redirect list from SPOKES, so the list is every remote spoke with an
# invite in git, this one, and local-cluster while the hub is a grid member.
spoke=${1:?usage: 46-spoke-join.sh <spoke>}
source "$(dirname "$0")/lib.sh"
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $spoke != local-cluster ]] || die "local-cluster is the hub itself: nothing to join"
[[ -f $(kcfg "$spoke") ]] || die "no kubeconfig for $spoke: expected $(kcfg "$spoke")"

SPOKES=$spoke bash "$root/bootstrap/45-import.sh"

values=$root/apps/grid-enrollment/manifests/values.yaml
if [[ $(yq ".grid-enrollment.invites | has(\"$spoke\")" "$values") == true ]]; then
  log "invite $spoke already in $values"
else
  # Append after the last entry of the invites map, in the file's own flow style.
  net=$(yq '.grid-enrollment.invites[] | .network' "$values" | head -1)
  awk -v s="$spoke" -v n="${net:-grid}" '
    /^  invites:/ { in_inv = 1; print; next }
    in_inv && !/^    [^ #]/ { printf "    %s: { network: %s }\n", s, n; in_inv = 0 }
    { print }' "$values" >"$values.new" && mv "$values.new" "$values"
  [[ $(yq ".grid-enrollment.invites | has(\"$spoke\")" "$values") == true ]] || die "couldn't add the invite to $values"
  log "added invites.$spoke to $values"
fi
dir=$root/spokes/clusters/$spoke/models
if [[ -d $dir ]]; then log "$dir exists"; else
  mkdir -p "$dir"; cp "$root/spokes/clusters/site-a/models/kustomization.yaml" "$dir/"; log "created $dir (the site-a pattern)"
fi

all=$(yq ".grid-enrollment.invites | keys | .[]" "$values" | tr "\n" " ")
[[ $(kc $HOST get managedcluster local-cluster -o json | jq -r --arg l "$LABEL_ENABLED" '.metadata.labels[$l] // ""') == true ]] && all="local-cluster $all"
# 36-portal-clients.sh reads each spoke's ingress domain through its kubeconfig and stops at a missing
# one. Leave those spokes out and say so, and have it add to maas-cli's list rather than replace it, so
# their callbacks stay.
keep="" missing=""
for s in $all; do
  if [[ -f $(kcfg "$s") ]]; then keep+="$s "; else missing=1; log "no kubeconfig for $s at $(kcfg "$s"): its portal callback stays as it is"; fi
done
SPOKES=$keep KEEP_OTHER_URIS=$missing bash "$root/bootstrap/36-portal-clients.sh"

bash "$root/hack/spoke-commit.sh" "$spoke" --ask
