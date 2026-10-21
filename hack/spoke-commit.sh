#!/usr/bin/env bash
# Commits and pushes one spoke's invite and models directory, which Argo CD reads from git:
#   bash hack/spoke-commit.sh <spoke> [--ask]      (make spoke-commit SPOKE=<spoke>)
# Stages only apps/grid-enrollment/manifests/values.yaml and spokes/clusters/<spoke>, never anything
# else, and pushes the current branch, which must be $GIT_REF. --ask (46-spoke-join.sh) shows the
# change and asks first when stdin is a terminal; otherwise it prints the make command and stops.
source "$(dirname "$0")/../bootstrap/lib.sh"
spoke=${1:?usage: spoke-commit.sh <spoke> [--ask]} ask=${2:-}
cd "$(dirname "$0")/.."
paths=(apps/grid-enrollment/manifests/values.yaml "spokes/clusters/$spoke")
msg="spoke $spoke: invite and models"
# The push must go where Argo CD reads, and publish nothing but this spoke's commit.
# host/owner/repo, lowercased, with any scheme, user or token removed (so it's also safe to print).
norm() { sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#:#/#; s#/$##; s#\.git$##' <<<"$1" | tr 'A-Z' 'a-z'; }
check_push() {
  local url extra
  [[ $branch == "$GIT_REF" ]] || die "on branch ${branch:-(detached)}, but Argo CD reads $GIT_REF: check out $GIT_REF, or set GIT_REF"
  [[ $remote ]] || die "branch $branch has no upstream: push it once with git push -u <remote> $branch, then rerun"
  [[ $up ]] || die "can't fetch $GIT_REF from remote $remote (git's error above): fix that, then rerun"
  url=$(git remote get-url --push "$remote")
  [[ $(norm "$url") == "$(norm "$GIT_REPO")" ]] || die "branch $branch pushes to remote $remote ($(norm "$url")), but Argo CD reads $(norm "$GIT_REPO"): push to that repository's branch, or set GIT_REPO"
  extra=$(git log --format='%h%x09%s' "$up..HEAD" | awk -F'\t' -v m="$msg" '$2 != m {print "  " $1 " " $2}')
  [[ -z $extra ]] || die "$branch has other unpushed commits, which a push would publish to Argo CD too:
$extra
Push or drop them first, then rerun make spoke-commit SPOKE=$spoke"
}
pending=1
git diff --quiet HEAD -- "${paths[@]}" && [[ -z $(git ls-files --others --exclude-standard -- "${paths[@]}") ]] && pending=
# Where a plain git push would go: the branch's push remote, the default push remote, or its upstream.
branch=$(git branch --show-current) remote=
[[ -z $branch ]] || remote=$(git config "branch.$branch.pushRemote" || git config remote.pushDefault || git config "branch.$branch.remote") || remote=
# A commit an earlier run made but couldn't push, compared with $GIT_REF where the push goes.
up=; [[ $remote ]] && git fetch -q "$remote" "$GIT_REF" && up=$(git rev-parse FETCH_HEAD)
unpushed=; [[ $up ]] && unpushed=$(git log --format=%s "$up..HEAD")
grep -qFx "$msg" <<<"$unpushed" || unpushed=
if [[ -z $pending && -z $unpushed && -n $up ]]; then log "$spoke: invite and models directory already committed and pushed"; exit 0; fi
if [[ $ask ]]; then
  if [[ ! -t 0 ]]; then
    log "Commit and push the invite and models directory (Argo CD reads $GIT_REF), then add $spoke in the console:"
    echo "  make spoke-commit SPOKE=$spoke"; exit 0
  fi
  check_push
  git --no-pager diff --stat HEAD -- "${paths[@]}"
  # The invites file is shared: show it whole, since another spoke's pending invite would go in this commit.
  git --no-pager diff HEAD -- "${paths[0]}"
  git ls-files --others --exclude-standard -- "${paths[@]}" | sed 's/^/ new: /'
  [[ -z $unpushed ]] || echo " committed earlier, not pushed: $msg"
  read -r -p "Commit and push to $GIT_REF? [y/N] " a
  [[ $a == [yY]* ]] || { log "not committed; later: make spoke-commit SPOKE=$spoke"; exit 0; }
fi
[[ $ask ]] || check_push
if [[ $pending ]]; then
  git add -- "${paths[@]}"
  git commit -q -m "$msg" -- "${paths[@]}"
fi
git push -q "$remote" "HEAD:refs/heads/$GIT_REF" || die "committed locally, but the push failed (above): fix it, then rerun make spoke-commit SPOKE=$spoke"
log "pushed $(git rev-parse --short HEAD) to $GIT_REF: add $spoke in the console"
