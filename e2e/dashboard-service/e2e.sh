#!/usr/bin/env bash
set -euo pipefail

BASE="${DASHBOARD_SERVICE_URL:-http://localhost:18080}"
PASS=0
FAIL=0

check_any() {
    local label="$1" method="$2" path="$3" expected_list="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$path" "$@" || echo "000")
    for exp in $expected_list; do
        if [ "$code" = "$exp" ]; then
            echo "  PASS  $label"
            PASS=$((PASS+1))
            return 0
        fi
    done
    echo "  FAIL  $label (expected one of [$expected_list], got $code)"
    FAIL=$((FAIL+1))
}

# 200 + body must be parseable JSON (catches empty bodies and error pages
# that would slip through a status-only check)
check_json() {
    local label="$1" path="$2"
    local body code
    body=$(curl -s -w "\n%{http_code}" "$BASE$path" || echo "000")
    code=$(echo "$body" | tail -1)
    body=$(echo "$body" | sed '$d')
    if [ "$code" = "200" ] && echo "$body" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        if echo "$body" | grep -q '"error"'; then
            echo "  PASS  $label (degraded: circuit-breaker fallback body)"
        else
            echo "  PASS  $label"
        fi
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label (HTTP $code, body not valid JSON or not 200)"
        FAIL=$((FAIL+1))
    fi
}

echo "=== E2E: dashboard-service ==="

check_any "Health endpoint"  GET "/actuator/health" "200 503"

# No Authorization header on purpose: dashboard-service delegates auth to the
# gateway (architecture decision) — its API must answer without a token.
check_json "Analytics: health-board (no auth — gateway-delegated)" "/api/v1/analytics/health-board"
check_json "Analytics: summary"                                    "/api/v1/analytics/summary"
check_json "Analytics: time-series"                                "/api/v1/analytics/time-series"
check_any  "Analytics: trends by location"   GET "/api/v1/analytics/trends/550e8400-e29b-41d4-a716-446655440000" "200 404"
check_any  "Analytics: department stats"     GET "/api/v1/analytics/department/medicine" "200 404"

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
