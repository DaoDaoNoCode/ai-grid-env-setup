source "$(dirname "${BASH_SOURCE[0]}")/../bootstrap/lib.sh"
set +e
FAILS=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS $name"; else echo "FAIL $name"; FAILS=$((FAILS+1)); fi; }
# uat <name> <likely cause> <command...>: checks what a user would see, and on failure says where to look.
uat() { local name=$1 hint=$2; shift 2
  if "$@" >/dev/null 2>&1; then echo "PASS $name"; else echo "FAIL $name"; echo "     likely: $hint"; FAILS=$((FAILS+1)); fi; }
pol() { kc $HOST get policy "ai-grid-policies.$2" -n "$1" -o jsonpath='{.status.compliant}' | grep -qx Compliant; }
# applications.argoproj.io: on an ACM hub, plain "application" means ACM's app.k8s.io kind.
app() { kc $HOST get applications.argoproj.io "$1" -n openshift-gitops -o jsonpath='{.status.sync.status} {.status.health.status}' | grep -qx 'Synced Healthy'; }
# MaaS's public URL on a spoke: Route maas-gateway-route, which Policy maas-route creates.
maas_url() {
  local r; r=$(kc "$1" get route maas-gateway-route -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null)
  echo "https://${r:-maas.$(kc "$1" get ingresses.config cluster -o jsonpath='{.spec.domain}')}"
}
export -f uat pol app maas_url
summary() { [[ $FAILS -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }; }
