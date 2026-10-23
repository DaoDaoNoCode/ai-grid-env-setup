#!/usr/bin/env bash
# Runs on the hub: everything a remote spoke needs before the console's Add (Task 11, steps 1 to 3):
#   bash bootstrap/46-spoke-join.sh <spoke>      (kubeconfig $KUBEDIR/<spoke>)
# Imports it into ACM, labels it ai-grid/network (Submariner with the hub), makes sure its invite and models directory exist in the working tree, and adds
# its portal callback to maas-cli. The invite lives in git: at a terminal it shows the change and asks
# before committing and pushing those two paths (hack/spoke-commit.sh); otherwise it prints the command.
# 36-portal-clients.sh sets the redirect list for every spoke invited in git, this one included, and
# local-cluster while it's a grid member, less inference spokes (portal_spokes in lib.sh).
spoke=${1:?usage: 46-spoke-join.sh <spoke>}
source "$(dirname "$0")/lib.sh"
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $spoke != local-cluster ]] || die "local-cluster is the hub itself: nothing to join"
[[ -f $(kcfg "$spoke") ]] || die "no kubeconfig for $spoke: expected $(kcfg "$spoke")"

SPOKES=$spoke bash "$root/bootstrap/45-import.sh"
# The cross-cluster network is a cluster prerequisite, like the GPU node: label ai-grid/network puts the
# spoke on Submariner with the hub now, before the Add, and keeps it there after Remove in the console,
# which would otherwise drop a combined spoke's MaaS route to the hub's maas-db.
kc $HOST label managedcluster "$spoke" "$LABEL_NETWORK=true" --overwrite >/dev/null || die "couldn't label $spoke $LABEL_NETWORK=true"
log "$spoke is on the cross-cluster network ($LABEL_NETWORK=true)"

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

# SPOKES names only this spoke, so the hub's membership alone decides local-cluster's callback.
SPOKES=$spoke bash "$root/bootstrap/36-portal-clients.sh"

bash "$root/hack/spoke-commit.sh" "$spoke" --ask
