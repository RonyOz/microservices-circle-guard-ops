#!/bin/bash
# Tunel local todos los services dev a los puertos que mobile/constants/Config.ts espera.
# Uso: ./scripts/port-forward-dev.sh    (Ctrl+C cierra todos los tuneles)
set -euo pipefail

NS="${NS:-dev}"

cleanup() {
    echo
    echo "[port-forward] cerrando tuneles..."
    pkill -P $$ -f "kubectl.*port-forward" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

echo "[port-forward] namespace=$NS"
echo "[port-forward] mapping localhost:<mobile_port> -> svc:<cluster_port>"

kubectl -n "$NS" port-forward svc/auth-service         8180:8081 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/notification-service 8082:8085 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/identity-service     8083:8082 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/form-service         8086:8084 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/gateway-service      8087:8083 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/promotion-service    8088:8086 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/mobile               8000:80   >/dev/null 2>&1 &

sleep 2
echo
echo "[port-forward] tuneles activos:"
echo "  Mobile UI:    http://localhost:8000"
echo "  Auth:         http://localhost:8180"
echo "  Identity:     http://localhost:8083"
echo "  Notification: http://localhost:8082"
echo "  Form:         http://localhost:8086"
echo "  Gateway:      http://localhost:8087"
echo "  Promotion:    http://localhost:8088"
echo
echo "[port-forward] Ctrl+C para cerrar todos."
wait
