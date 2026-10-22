#!/usr/bin/env bash
# make login: logs in to each cluster in clusters.local.yaml, or only those named, and writes its
# kubeconfig, with the API's CA embedded, to $CLUSTERS_CACHE/<name>:
#   bash hack/cluster-login.sh [host|<spoke> ...]      (host is the file's hub)
# On first use it saves the self-signed root CA the API presents (trust on first use) and prints its
# fingerprint. The OAuth route is trusted through the system store, or the same way if that fails.
# Tokens last a day; run it again when one expires. The password goes from the file to curl through
# a pipe: never argv, a shell variable or output. curl -q ignores ~/.curlrc, so no --verbose or
# --insecure there applies. Prints only user and server.
source "$(dirname "$0")/../bootstrap/lib.sh"
set +x
[[ -f $CLUSTERS_FILE ]] || die "no $CLUSTERS_FILE. Create it from the example, fill in every <placeholder>, then rerun:
  cp $REPO_ROOT/clusters.example.yaml $CLUSTERS_FILE"
umask 077
chmod go-rwx "$CLUSTERS_FILE"
mkdir -p "$CLUSTERS_CACHE" && chmod 700 "$CLUSTERS_CACHE"
key() { if [[ $1 == host ]]; then echo .hub; else echo ".spokes[\"$1\"]"; fi; }
field() { yq -r "$(key "$1").$2 // \"\"" "$CLUSTERS_FILE"; }
# root_ca <host:port> <file>: saves the last certificate in the chain the server presents.
root_ca() {
  { echo | openssl s_client -connect "$1" -servername "${1%:*}" -showcerts 2>/dev/null || true; } |
    awk '/BEGIN CERTIFICATE/{c=""} {c=c $0 "\n"} /END CERTIFICATE/{last=c} END{printf "%s", last}' >"$2"
  openssl x509 -in "$2" -noout >/dev/null 2>&1 || { rm -f "$2"; die "$name: no TLS certificate from $1: check its server in $CLUSTERS_FILE"; }
  log "saved the CA of $1: $(openssl x509 -in "$2" -noout -subject -fingerprint -sha256 | tr '\n' ' ')"
}
# basic <name>: the Basic auth header line, built in a pipe so the password never sits in a variable.
basic() {
  printf 'Authorization: Basic '
  { printf '%s:' "$(field "$1" user)"; yq -r "$(key "$1").password" "$CLUSTERS_FILE" | tr -d '\n'; } | base64 | tr -d '\n'
  printf '\n'
}
login() {
  local name=$1 server user hp ca authz ohp oca loc token who
  server=$(field "$name" server) user=$(field "$name" user)
  [[ $(yq "$(key "$name").password // \"\" | length > 0" "$CLUSTERS_FILE") == true ]] || die "$name: no password in $CLUSTERS_FILE"
  [[ $server$user != *"<"*">"* && $(yq "$(key "$name") | (.password | select(tag == \"!!str\") | test(\"^<[^>]*>$\")) // false" "$CLUSTERS_FILE") == false ]] ||
    die "$name: still has a <placeholder> in $CLUSTERS_FILE: fill in its server, user and password"
  [[ $server =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ && -n $user ]] || die "$name: needs server (https://<host>[:port]) and user in $CLUSTERS_FILE"
  server=${server%/}
  hp=${server#https://}; hp=${hp%%/*}; [[ $hp == *:* ]] || hp+=:443
  ca=$CLUSTERS_CACHE/$name.ca.crt
  [[ -s $ca ]] || root_ca "$hp" "$ca"
  local disc rc=0
  disc=$(curl -q -fsS --cacert "$ca" "$server/.well-known/oauth-authorization-server") || rc=$?
  [[ $rc != 60 ]] || die "the saved CA for $name no longer matches $server (rebuilt cluster?): rm $ca and rerun make login"
  [[ $rc == 0 ]] || die "$name: can't reach $server (curl exit $rc)"
  authz=$(jq -r '.authorization_endpoint // ""' <<<"$disc")
  [[ $authz == https://* ]] || die "$name: no OAuth server at $server"
  # The challenging client answers Basic auth with a redirect whose fragment holds the token. The
  # OAuth route often has a public certificate: trust the system store first. Only when that fails
  # verification (curl 60, before any request is sent) on the first login, save the route's root and
  # trust that from then on. Once the system store has verified it, never fall back: a certificate
  # that stops verifying is refused, not saved.
  authorize() {
    curl -q -sS -o /dev/null -D - "$@" -H 'X-CSRF-Token: 1' -H @<(basic "$name") \
      "$authz?client_id=openshift-challenging-client&response_type=token"
  }
  local hdrs sys=$CLUSTERS_CACHE/$name.oauth-system-trust
  rc=0 oca=$CLUSTERS_CACHE/$name.oauth-ca.crt
  if [[ -s $oca ]]; then
    hdrs=$(authorize --cacert "$oca") || rc=$?
    [[ $rc != 60 ]] || die "the saved CA for $name's OAuth server no longer matches (rebuilt cluster?): rm $oca and rerun make login"
    [[ $rc == 0 ]] || die "$name: can't reach the OAuth server at ${authz%/oauth/*} (curl exit $rc)"
  else
    hdrs=$(authorize 2>/dev/null) || rc=$?
    if [[ $rc == 0 ]]; then
      : >"$sys"
    elif [[ $rc == 60 && ! -e $sys ]]; then
      ohp=${authz#https://}; ohp=${ohp%%/*}; [[ $ohp == *:* ]] || ohp+=:443
      root_ca "$ohp" "$oca"
      hdrs=$(authorize --cacert "$oca")
    elif [[ $rc == 60 ]]; then
      die "$name: the OAuth server's certificate no longer verifies; it did before. Check it, then remove $sys to trust a new one"
    else
      die "$name: can't reach the OAuth server at ${authz%/oauth/*} (curl exit $rc)"
    fi
  fi
  loc=$(tr -d '\r' <<<"$hdrs" | sed -n 's/^[Ll]ocation: //p')
  token=$(sed -n 's/.*[#&]access_token=\([^&]*\).*/\1/p' <<<"$loc")
  [[ -z $token || $token =~ ^[A-Za-z0-9_~.-]+$ ]] || die "$name: the OAuth server returned a malformed token"
  [[ -n $token ]] || die "$name: login as $user at $server failed: check the user and password"
  who=$(curl -q -fsS --cacert "$ca" -H @<(printf 'Authorization: Bearer %s\n' "$token") "$server/apis/user.openshift.io/v1/users/~" | jq -r .metadata.name)
  local tmp; tmp=$(mktemp "$CLUSTERS_CACHE/.$name.XXXXXX")
  printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: %s\n  cluster:\n    server: %s\n    certificate-authority-data: %s\n' \
    "$name" "$server" "$(base64 <"$ca" | tr -d '\n')" >"$tmp"
  printf 'users:\n- name: %s\n  user:\n    token: %s\ncontexts:\n- name: %s\n  context: {cluster: %s, user: %s}\ncurrent-context: %s\n' \
    "$name" "$token" "$name" "$name" "$name" "$name" >>"$tmp"
  mv "$tmp" "$CLUSTERS_CACHE/$name"
  log "logged in to $name as $who at $server ($CLUSTERS_CACHE/$name)"
}
names=("$@")
if [[ ${#names[@]} -eq 0 ]]; then
  [[ $(yq 'has("hub")' "$CLUSTERS_FILE") == true ]] && names+=(host)
  while read -r s; do [[ -n $s ]] && names+=("$s"); done < <(yq -r '.spokes // {} | keys | .[]' "$CLUSTERS_FILE")
fi
for n in "${names[@]}"; do
  [[ $n =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "$n: not a cluster name"
  [[ $(yq "$(key "$n") != null" "$CLUSTERS_FILE") == true ]] || die "$n: not in $CLUSTERS_FILE"
  login "$n"
done
