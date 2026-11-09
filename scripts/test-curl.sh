#!/usr/bin/env bash
# curl evidence: the application answers "Hello SOC-MSE" over HTTPS through the VIP and
# every node, with the certificate issued by cert-manager, and the content comes from the
# ConfigMap. Output: report/12-curl.log
#
#   scripts/test-curl.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VIP=192.168.122.200
APP_HOST=hello.soc-mse.local
APP_PORT=30443
LOG=report/12-curl.log
TARGETS=("VIP:${VIP}" "cp1:192.168.122.244" "cp2:192.168.122.47" "cp3:192.168.122.76")

exec > >(tee "$LOG") 2>&1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

app_url="https://${APP_HOST}:${APP_PORT}/"
fail=0

log "=== HTTPS request through the VIP and each node ==="
for target in "${TARGETS[@]}"; do
  name="${target%%:*}"
  ip="${target#*:}"
  out="$(curl -sk --max-time 5 -w ' HTTP=%{http_code}' --resolve "${APP_HOST}:${APP_PORT}:${ip}" "$app_url" || true)"
  printf '%-4s %-16s %s\n' "$name" "$ip" "$out"
  [[ "$out" == *"Hello SOC-MSE"*"HTTP=200"* ]] || fail=1
done

echo
log "=== TLS handshake (curl -v) ==="
curl -skv --max-time 5 --resolve "${APP_HOST}:${APP_PORT}:${VIP}" "$app_url" 2>&1 \
  | grep -E 'SSL connection using|subject:|issuer:|start date|expire date|subjectAltName|< HTTP/' || true

echo
log "=== Certificate presented by the Gateway ==="
openssl s_client -connect "${VIP}:${APP_PORT}" -servername "$APP_HOST" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName -dates

echo
log "=== Page content in ConfigMap nginx-hello-config ==="
ansible cp1 -b -m command \
  -a "kubectl --kubeconfig=/etc/kubernetes/admin.conf get configmap nginx-hello-config -n default -o 'jsonpath={.data.index\.html}'" 2>/dev/null

echo
log "=== Requests the Gateway rejects ==="
code=0; curl -s --max-time 5 -o /dev/null "http://${VIP}:${APP_PORT}/" || code=$?
echo "plain HTTP (no TLS)          -> curl exit ${code} (connection reset expected)"
code=0; curl -sk --max-time 5 -o /dev/null "https://${VIP}:${APP_PORT}/" || code=$?
echo "HTTPS without the hostname   -> curl exit ${code} (no SNI match, connection reset expected)"

echo
if [[ $fail -eq 0 ]]; then
  log "PASS: Hello SOC-MSE over HTTPS through the VIP and all 3 nodes"
else
  log "FAIL: at least one target did not return Hello SOC-MSE with HTTP 200"
  exit 1
fi
