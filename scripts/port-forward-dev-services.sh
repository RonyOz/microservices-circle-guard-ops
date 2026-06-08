#!/bin/bash
# Tunel local para los 9 microservicios del proyecto.
# Uso: ./scripts/port-forward-dev-services.sh [namespace]  (default: dev)
set -euo pipefail

NS="${1:-dev}"

cleanup() {
    echo
    echo "[port-forward] cerrando tuneles de servicios..."
    pkill -P $$ -f "kubectl.*8180:8081" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8082:8085" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8083:8082" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8084:8087" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8085:8088" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8086:8084" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8087:8083" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8088:8086" 2>/dev/null || true
    pkill -P $$ -f "kubectl.*8080:80" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

echo "[port-forward] namespace=$NS"

# Mapeo local:service — coincide con mobile/constants/Config.ts
kubectl -n "$NS" port-forward svc/auth-service            8180:8081 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/notification-service    8082:8085 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/identity-service        8083:8082 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/dashboard-service       8084:8087 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/file-service            8085:8088 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/form-service            8086:8084 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/gateway-service         8087:8083 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/promotion-service       8088:8086 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/mobile                  8080:80   >/dev/null 2>&1 &

sleep 2
echo
echo "[port-forward] tuneles de servicios activos (coincide con Config.ts):"
echo "  auth-service:         http://localhost:8180"
echo "  notification-service: http://localhost:8082"
echo "  identity-service:     http://localhost:8083"
echo "  dashboard-service:    http://localhost:8084"
echo "  file-service:         http://localhost:8085"
echo "  form-service:         http://localhost:8086"
echo "  gateway-service:      http://localhost:8087"
echo "  promotion-service:    http://localhost:8088"
echo "  mobile:               http://localhost:8080"
echo
echo "[port-forward] Ctrl+C para cerrar todos."
wait
