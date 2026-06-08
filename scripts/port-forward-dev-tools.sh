#!/bin/bash
# Tunel local para servicios de observabilidad y dev tools.
# Uso: ./scripts/port-forward-dev-tools.sh [namespace]  (default: dev)
set -euo pipefail

NS="${1:-dev}"

cleanup() {
    echo
    echo "[port-forward] cerrando tuneles..."
    pkill -P $$ -f "kubectl.*port-forward" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

echo "[port-forward] namespace=$NS"

kubectl -n "$NS" port-forward svc/grafana    3000:3000   >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/prometheus 9090:9090   >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/jaeger     16686:16686 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/mailhog    8025:8025   >/dev/null 2>&1 &

sleep 2
echo
echo "[port-forward] tuneles activos:"
echo "  Grafana:     http://localhost:3000"
echo "  Prometheus:  http://localhost:9090"
echo "  Jaeger:      http://localhost:16686"
echo "  MailHog:     http://localhost:8025"
echo
echo "[port-forward] Ctrl+C para cerrar todos."
wait
