#!/usr/bin/env bash
set -euo pipefail

BASE="http://localhost:18080"
PASS=0; FAIL=0

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

echo "=== E2E: gateway-service ==="

check_any "Health endpoint"           GET  "/actuator/health"                    "200 503"
check "Validate empty body"           POST "/api/v1/gate/validate"              "400" \
    -H 'Content-Type: application/json' \
    -d '{}'
check "Validate malformed token"     POST "/api/v1/gate/validate"              "200" \
    -H 'Content-Type: application/json' \
    -d '{"token":"invalid-qr-code"}'

echo "--- Results: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
