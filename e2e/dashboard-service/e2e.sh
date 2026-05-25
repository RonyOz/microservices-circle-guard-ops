#!/usr/bin/env bash
set -euo pipefail

BASE="${DASHBOARD_SERVICE_URL:-http://localhost:8087}"
PASS=0
FAIL=0

check() {
    local label="$1" method="$2" path="$3" expected="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE$path" "$@" || echo "000")
    if [ "$code" = "$expected" ]; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label (expected $expected, got $code)"
        FAIL=$((FAIL+1))
    fi
}

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

echo "=== E2E: dashboard-service ==="

check_any "Health endpoint"             GET  "/actuator/health"                    "200 503"
check     "Analytics: unauthenticated"  GET  "/api/v1/analytics/health-board"      "401"
check     "Analytics: summary unauth"   GET  "/api/v1/analytics/summary"           "401"
check     "Analytics: time-series unauth" GET "/api/v1/analytics/time-series"      "401"

AUTH_HEADER=""
TOKEN=$(curl -s -X POST "${GATEWAY_URL:-http://localhost:8086}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
    AUTH_HEADER="Authorization: Bearer $TOKEN"
    echo "  INFO  Token obtained"

    check_any "Analytics: health-board (auth)"  GET "/api/v1/analytics/health-board"        "200 204" -H "$AUTH_HEADER"
    check_any "Analytics: summary (auth)"       GET "/api/v1/analytics/summary"             "200 204" -H "$AUTH_HEADER"
    check_any "Analytics: trends by location"   GET "/api/v1/analytics/trends/loc-001"      "200 404" -H "$AUTH_HEADER"
    check_any "Analytics: department stats"     GET "/api/v1/analytics/department/medicine" "200 404" -H "$AUTH_HEADER"
    check_any "Analytics: time-series (auth)"   GET "/api/v1/analytics/time-series"         "200 204" -H "$AUTH_HEADER"
else
    echo "  SKIP  Authenticated tests — no token from gateway"
fi

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
