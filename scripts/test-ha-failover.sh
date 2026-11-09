#!/usr/bin/env bash
# HA evidence: when Keepalived or HAProxy stops on the VIP holder (cp1), the VIP moves
# to cp2, the Kubernetes API and the application stay reachable through the VIP, and the
# VIP returns to cp1 once the service is started again. Output: report/11-ha-failover.log
#
#   scripts/test-ha-failover.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VIP=192.168.122.200
APP_HOST=hello.soc-mse.local
APP_PORT=30443
MASTER=cp1
BACKUP=cp2
LOG=report/11-ha-failover.log

exec > >(tee "$LOG") 2>&1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Always leave HAProxy and Keepalived running on the master, even if a check fails
restore_services() {
  ansible "$MASTER" -b -m systemd -a "name=haproxy state=started" >/dev/null 2>&1 || true
  ansible "$MASTER" -b -m systemd -a "name=keepalived state=started" >/dev/null 2>&1 || true
}
trap restore_services EXIT

vip_holder() {
  ansible control_plane -o -m shell -a "ip -4 -br addr show | grep -qw ${VIP} && echo HAS_VIP || echo -" 2>/dev/null \
    | awk '/HAS_VIP/ {print $1}' | paste -sd, -
}

wait_vip() {
  local want="$1" holder=""
  for _ in $(seq 1 15); do
    holder="$(vip_holder)"
    if [[ "$holder" == "$want" ]]; then
      log "VIP ${VIP} is on ${holder}"
      return 0
    fi
    sleep 2
  done
  log "FAIL: VIP is on '${holder}', expected ${want}"
  return 1
}

# kubectl on cp3 uses admin.conf, whose server is the VIP (https://192.168.122.200:8443)
check_api() {
  ansible cp3 -b -m shell -a "kubectl --kubeconfig=/etc/kubernetes/admin.conf config view -o jsonpath='{.clusters[0].cluster.server}'; echo; kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes" 2>/dev/null
}

check_app() {
  local out
  out="$(curl -sk --max-time 5 -w ' HTTP=%{http_code}' --resolve "${APP_HOST}:${APP_PORT}:${VIP}" "https://${APP_HOST}:${APP_PORT}/" || true)"
  echo "curl https://${APP_HOST}:${APP_PORT} via ${VIP} -> ${out}"
  if [[ "$out" != *"Hello SOC-MSE"* ]]; then
    log "FAIL: application not reachable through the VIP"
    return 1
  fi
}

log "=== Initial state ==="
wait_vip "$MASTER"
check_app

for svc in keepalived haproxy; do
  echo
  log "=== Scenario: stop ${svc} on ${MASTER} ==="
  ansible "$MASTER" -b -m systemd -a "name=${svc} state=stopped" >/dev/null 2>&1
  log "${svc} stopped on ${MASTER}"
  wait_vip "$BACKUP"
  log "Kubernetes API through the VIP:"
  check_api
  log "Application through the VIP:"
  check_app

  log "=== Start ${svc} on ${MASTER} again ==="
  ansible "$MASTER" -b -m systemd -a "name=${svc} state=started" >/dev/null 2>&1
  wait_vip "$MASTER"
  check_app
done

echo
log "PASS: the VIP moved to ${BACKUP} when keepalived or haproxy stopped on ${MASTER}, API and application stayed reachable, and the VIP returned to ${MASTER}"
