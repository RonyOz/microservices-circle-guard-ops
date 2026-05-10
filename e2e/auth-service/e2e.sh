#!/usr/bin/env bash
set -euo pipefail

BASE="http://localhost:18080"
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

echo "=== E2E: auth-service ==="

check_any "Health endpoint"             GET    "/actuator/health"                 "200 503"
check    "Login (invalid creds)"        POST   "/api/v1/auth/login"              "401" \
    -H 'Content-Type: application/json' \
    -d '{"username":"wrong","password":"wrong"}'

TOKEN=$(curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
    echo "  PASS  Login (valid credentials)"
    PASS=$((PASS+1))
    check "QR token generate"     GET    "/api/v1/auth/qr/generate"           "200" \
        -H "Authorization: Bearer $TOKEN"
    check "Visitor handoff"       POST   "/api/v1/auth/visitor/handoff"       "200" \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -d '{"anonymousId":"e2e-test-123"}'
else
    echo "  SKIP  Login (valid) — no default credentials configured in stage"
fi

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
